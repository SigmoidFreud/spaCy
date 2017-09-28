# cython: infer_types=True
# cython: profile=True
# cython: cdivision=True
# cython: boundscheck=False
# coding: utf-8
from __future__ import unicode_literals, print_function

from collections import Counter, OrderedDict
import ujson
import json
import contextlib

from libc.math cimport exp
cimport cython
cimport cython.parallel
import cytoolz
import dill

import numpy.random
cimport numpy as np

from libcpp.vector cimport vector
from cpython.ref cimport PyObject, Py_INCREF, Py_XDECREF
from cpython.exc cimport PyErr_CheckSignals
from libc.stdint cimport uint32_t, uint64_t
from libc.string cimport memset, memcpy
from libc.stdlib cimport malloc, calloc, free
from thinc.typedefs cimport weight_t, class_t, feat_t, atom_t, hash_t
from thinc.linear.avgtron cimport AveragedPerceptron
from thinc.linalg cimport VecVec
from thinc.structs cimport SparseArrayC, FeatureC, ExampleC
from thinc.extra.eg cimport Example
from thinc.extra.search cimport Beam

from cymem.cymem cimport Pool, Address
from murmurhash.mrmr cimport hash64
from preshed.maps cimport MapStruct
from preshed.maps cimport map_get

from thinc.api import layerize, chain, noop, clone, with_flatten
from thinc.neural import Model, Affine, ReLu, Maxout
from thinc.neural._classes.batchnorm import BatchNorm as BN
from thinc.neural._classes.selu import SELU
from thinc.neural._classes.layernorm import LayerNorm
from thinc.neural.ops import NumpyOps, CupyOps
from thinc.neural.util import get_array_module

from .. import util
from ..util import get_async, get_cuda_stream
from .._ml import zero_init, PrecomputableAffine, PrecomputableMaxouts
from .._ml import Tok2Vec, doc2feats, rebatch, fine_tune
from .._ml import Residual, drop_layer, flatten
from .._ml import link_vectors_to_models
from ..compat import json_dumps

from . import _parse_features
from ._parse_features cimport CONTEXT_SIZE
from ._parse_features cimport fill_context
from .stateclass cimport StateClass
from ._state cimport StateC
from . import nonproj
from .transition_system import OracleError
from .transition_system cimport TransitionSystem, Transition
from ..structs cimport TokenC
from ..tokens.doc cimport Doc
from ..strings cimport StringStore
from ..gold cimport GoldParse
from ..attrs cimport ID, TAG, DEP, ORTH, NORM, PREFIX, SUFFIX, TAG
from . import _beam_utils

USE_FINE_TUNE = True

def get_templates(*args, **kwargs):
    return []

USE_FTRL = True
DEBUG = False
def set_debug(val):
    global DEBUG
    DEBUG = val


cdef class precompute_hiddens:
    '''Allow a model to be "primed" by pre-computing input features in bulk.

    This is used for the parser, where we want to take a batch of documents,
    and compute vectors for each (token, position) pair. These vectors can then
    be reused, especially for beam-search.

    Let's say we're using 12 features for each state, e.g. word at start of
    buffer, three words on stack, their children, etc. In the normal arc-eager
    system, a document of length N is processed in 2*N states. This means we'll
    create 2*N*12 feature vectors --- but if we pre-compute, we only need
    N*12 vector computations. The saving for beam-search is much better:
    if we have a beam of k, we'll normally make 2*N*12*K computations --
    so we can save the factor k. This also gives a nice CPU/GPU division:
    we can do all our hard maths up front, packed into large multiplications,
    and do the hard-to-program parsing on the CPU.
    '''
    cdef int nF, nO, nP
    cdef bint _is_synchronized
    cdef public object ops
    cdef np.ndarray _features
    cdef np.ndarray _cached
    cdef object _cuda_stream
    cdef object _bp_hiddens

    def __init__(self, batch_size, tokvecs, lower_model, cuda_stream=None, drop=0.):
        gpu_cached, bp_features = lower_model.begin_update(tokvecs, drop=drop)
        cdef np.ndarray cached
        if not isinstance(gpu_cached, numpy.ndarray):
            # Note the passing of cuda_stream here: it lets
            # cupy make the copy asynchronously.
            # We then have to block before first use.
            cached = gpu_cached.get(stream=cuda_stream)
        else:
            cached = gpu_cached
        self.nF = cached.shape[1]
        self.nO = cached.shape[2]
        self.nP = getattr(lower_model, 'nP', 1)
        self.ops = lower_model.ops
        self._is_synchronized = False
        self._cuda_stream = cuda_stream
        self._cached = cached
        self._bp_hiddens = bp_features

    cdef const float* get_feat_weights(self) except NULL:
        if not self._is_synchronized \
        and self._cuda_stream is not None:
            self._cuda_stream.synchronize()
            self._is_synchronized = True
        return <float*>self._cached.data

    def __call__(self, X):
        return self.begin_update(X)[0]

    def begin_update(self, token_ids, drop=0.):
        cdef np.ndarray state_vector = numpy.zeros((token_ids.shape[0], self.nO*self.nP), dtype='f')
        # This is tricky, but (assuming GPU available);
        # - Input to forward on CPU
        # - Output from forward on CPU
        # - Input to backward on GPU!
        # - Output from backward on GPU
        bp_hiddens = self._bp_hiddens

        feat_weights = self.get_feat_weights()
        cdef int[:, ::1] ids = token_ids
        sum_state_features(<float*>state_vector.data,
            feat_weights, &ids[0,0],
            token_ids.shape[0], self.nF, self.nO*self.nP)
        state_vector, bp_nonlinearity = self._nonlinearity(state_vector)

        def backward(d_state_vector, sgd=None):
            if bp_nonlinearity is not None:
                d_state_vector = bp_nonlinearity(d_state_vector, sgd)
            # This will usually be on GPU
            if isinstance(d_state_vector, numpy.ndarray):
                d_state_vector = self.ops.xp.array(d_state_vector)
            d_tokens = bp_hiddens((d_state_vector, token_ids), sgd)
            return d_tokens
        return state_vector, backward

    def _nonlinearity(self, state_vector):
        if self.nP == 1:
            return state_vector, None
        state_vector = state_vector.reshape(
            (state_vector.shape[0], state_vector.shape[1]//self.nP, self.nP))
        best, which = self.ops.maxout(state_vector)
        def backprop(d_best, sgd=None):
            return self.ops.backprop_maxout(d_best, which, self.nP)
        return best, backprop



cdef void sum_state_features(float* output,
        const float* cached, const int* token_ids, int B, int F, int O) nogil:
    cdef int idx, b, f, i
    cdef const float* feature
    for b in range(B):
        for f in range(F):
            if token_ids[f] < 0:
                continue
            idx = token_ids[f] * F * O + f*O
            feature = &cached[idx]
            for i in range(O):
                output[i] += feature[i]
        output += O
        token_ids += F


cdef void cpu_log_loss(float* d_scores,
        const float* costs, const int* is_valid, const float* scores,
        int O) nogil:
    """Do multi-label log loss"""
    cdef double max_, gmax, Z, gZ
    best = arg_max_if_gold(scores, costs, is_valid, O)
    guess = arg_max_if_valid(scores, is_valid, O)
    Z = 1e-10
    gZ = 1e-10
    max_ = scores[guess]
    gmax = scores[best]
    for i in range(O):
        if is_valid[i]:
            Z += exp(scores[i] - max_)
            if costs[i] <= costs[best]:
                gZ += exp(scores[i] - gmax)
    for i in range(O):
        if not is_valid[i]:
            d_scores[i] = 0.
        elif costs[i] <= costs[best]:
            d_scores[i] = (exp(scores[i]-max_) / Z) - (exp(scores[i]-gmax)/gZ)
        else:
            d_scores[i] = exp(scores[i]-max_) / Z


cdef void cpu_regression_loss(float* d_scores,
        const float* costs, const int* is_valid, const float* scores,
        int O) nogil:
    cdef float eps = 2.
    best = arg_max_if_gold(scores, costs, is_valid, O)
    for i in range(O):
        if not is_valid[i]:
            d_scores[i] = 0.
        elif scores[i] < scores[best]:
            d_scores[i] = 0.
        else:
            # I doubt this is correct?
            # Looking for something like Huber loss
            diff = scores[i] - -costs[i]
            if diff > eps:
                d_scores[i] = eps
            elif diff < -eps:
                d_scores[i] = -eps
            else:
                d_scores[i] = diff


cdef class Parser:
    """
    Base class of the DependencyParser and EntityRecognizer.
    """
    @classmethod
    def Model(cls, nr_class, token_vector_width=128, hidden_width=200, depth=1, **cfg):
        depth = util.env_opt('parser_hidden_depth', depth)
        token_vector_width = util.env_opt('token_vector_width', token_vector_width)
        hidden_width = util.env_opt('hidden_width', hidden_width)
        parser_maxout_pieces = util.env_opt('parser_maxout_pieces', 2)
        embed_size = util.env_opt('embed_size', 7000)
        tok2vec = Tok2Vec(token_vector_width, embed_size,
                          pretrained_dims=cfg.get('pretrained_dims', 0))
        tok2vec = chain(tok2vec, flatten)
        if parser_maxout_pieces == 1:
            lower = PrecomputableAffine(hidden_width if depth >= 1 else nr_class,
                        nF=cls.nr_feature,
                        nI=token_vector_width)
        else:
            lower = PrecomputableMaxouts(hidden_width if depth >= 1 else nr_class,
                        nF=cls.nr_feature,
                        nP=parser_maxout_pieces,
                        nI=token_vector_width)

        with Model.use_device('cpu'):
            if depth == 0:
                upper = chain()
                upper.is_noop = True
            else:
                upper = chain(
                    clone(Maxout(hidden_width), depth-1),
                    zero_init(Affine(nr_class, hidden_width, drop_factor=0.0))
                )
                upper.is_noop = False
        # TODO: This is an unfortunate hack atm!
        # Used to set input dimensions in network.
        lower.begin_training(lower.ops.allocate((500, token_vector_width)))
        upper.begin_training(upper.ops.allocate((500, hidden_width)))
        cfg = {
            'nr_class': nr_class,
            'depth': depth,
            'token_vector_width': token_vector_width,
            'hidden_width': hidden_width,
            'maxout_pieces': parser_maxout_pieces
        }
        return (tok2vec, lower, upper), cfg

    def __init__(self, Vocab vocab, moves=True, model=True, **cfg):
        """
        Create a Parser.

        Arguments:
            vocab (Vocab):
                The vocabulary object. Must be shared with documents to be processed.
                The value is set to the .vocab attribute.
            moves (TransitionSystem):
                Defines how the parse-state is created, updated and evaluated.
                The value is set to the .moves attribute unless True (default),
                in which case a new instance is created with Parser.Moves().
            model (object):
                Defines how the parse-state is created, updated and evaluated.
                The value is set to the .model attribute unless True (default),
                in which case a new instance is created with Parser.Model().
            **cfg:
                Arbitrary configuration parameters. Set to the .cfg attribute
        """
        self.vocab = vocab
        if moves is True:
            self.moves = self.TransitionSystem(self.vocab.strings, {})
        else:
            self.moves = moves
        if 'beam_width' not in cfg:
            cfg['beam_width'] = util.env_opt('beam_width', 1)
        if 'beam_density' not in cfg:
            cfg['beam_density'] = util.env_opt('beam_density', 0.0)
        if 'pretrained_dims' not in cfg:
            cfg['pretrained_dims'] = self.vocab.vectors.data.shape[1]
        cfg.setdefault('cnn_maxout_pieces', 3)
        self.cfg = cfg
        if 'actions' in self.cfg:
            for action, labels in self.cfg.get('actions', {}).items():
                for label in labels:
                    self.moves.add_action(action, label)
        self.model = model
        self._multitasks = []

    def __reduce__(self):
        return (Parser, (self.vocab, self.moves, self.model), None, None)

    def __call__(self, Doc doc, beam_width=None, beam_density=None):
        """
        Apply the parser or entity recognizer, setting the annotations onto the Doc object.

        Arguments:
            doc (Doc): The document to be processed.
        Returns:
            None
        """
        if beam_width is None:
            beam_width = self.cfg.get('beam_width', 1)
        if beam_density is None:
            beam_density = self.cfg.get('beam_density', 0.0)
        cdef Beam beam
        if beam_width == 1:
            states = self.parse_batch([doc])
            self.set_annotations([doc], states)
            return doc
        else:
            beam = self.beam_parse([doc],
                        beam_width=beam_width, beam_density=beam_density)[0]
            output = self.moves.get_beam_annot(beam)
            state = <StateClass>beam.at(0)
            self.set_annotations([doc], [state])
            _cleanup(beam)
            return output

    def pipe(self, docs, int batch_size=1000, int n_threads=2,
             beam_width=None, beam_density=None):
        """
        Process a stream of documents.

        Arguments:
            stream: The sequence of documents to process.
            batch_size (int):
                The number of documents to accumulate into a working set.
            n_threads (int):
                The number of threads with which to work on the buffer in parallel.
        Yields (Doc): Documents, in order.
        """
        if beam_width is None:
            beam_width = self.cfg.get('beam_width', 1)
        if beam_density is None:
            beam_density = self.cfg.get('beam_density', 0.0)
        cdef Doc doc
        cdef Beam beam
        for docs in cytoolz.partition_all(batch_size, docs):
            docs = list(docs)
            if beam_width == 1:
                parse_states = self.parse_batch(docs)
                beams = []
            else:
                beams = self.beam_parse(docs,
                            beam_width=beam_width, beam_density=beam_density)
                parse_states = []
                for beam in beams:
                    parse_states.append(<StateClass>beam.at(0))
            self.set_annotations(docs, parse_states)
            yield from docs

    def parse_batch(self, docs):
        cdef:
            precompute_hiddens state2vec
            StateClass state
            Pool mem
            const float* feat_weights
            StateC* st
            vector[StateC*] next_step, this_step
            int nr_class, nr_feat, nr_piece, nr_dim, nr_state
        if isinstance(docs, Doc):
            docs = [docs]

        cuda_stream = get_cuda_stream()
        (tokvecs, bp_tokvecs), state2vec, vec2scores = self.get_batch_model(docs, cuda_stream,
                                                                            0.0)

        nr_state = len(docs)
        nr_class = self.moves.n_moves
        nr_dim = tokvecs.shape[1]
        nr_feat = self.nr_feature
        nr_piece = state2vec.nP

        states = self.moves.init_batch(docs)
        for state in states:
            if not state.c.is_final():
                next_step.push_back(state.c)

        feat_weights = state2vec.get_feat_weights()
        cdef int i
        cdef np.ndarray token_ids = numpy.zeros((nr_state, nr_feat), dtype='i')
        cdef np.ndarray is_valid = numpy.zeros((nr_state, nr_class), dtype='i')
        cdef np.ndarray scores
        c_token_ids = <int*>token_ids.data
        c_is_valid = <int*>is_valid.data
        cdef int has_hidden = not getattr(vec2scores, 'is_noop', False)
        cdef int nr_step
        while not next_step.empty():
            nr_step = next_step.size()
            if not has_hidden:
                for i in cython.parallel.prange(nr_step, num_threads=6,
                                                nogil=True):
                    self._parse_step(next_step[i],
                        feat_weights, nr_class, nr_feat, nr_piece)
            else:
                for i in range(nr_step):
                    st = next_step[i]
                    st.set_context_tokens(&c_token_ids[i*nr_feat], nr_feat)
                    self.moves.set_valid(&c_is_valid[i*nr_class], st)
                vectors = state2vec(token_ids[:next_step.size()])
                scores = vec2scores(vectors)
                c_scores = <float*>scores.data
                for i in range(nr_step):
                    st = next_step[i]
                    guess = arg_max_if_valid(
                        &c_scores[i*nr_class], &c_is_valid[i*nr_class], nr_class)
                    action = self.moves.c[guess]
                    action.do(st, action.label)
            this_step, next_step = next_step, this_step
            next_step.clear()
            for st in this_step:
                if not st.is_final():
                    next_step.push_back(st)
        return states

    def beam_parse(self, docs, int beam_width=3, float beam_density=0.001):
        cdef Beam beam
        cdef np.ndarray scores
        cdef Doc doc
        cdef int nr_class = self.moves.n_moves
        cdef StateClass stcls, output
        cuda_stream = get_cuda_stream()
        (tokvecs, bp_tokvecs), state2vec, vec2scores = self.get_batch_model(docs, cuda_stream,
                                                                            0.0)
        beams = []
        cdef int offset = 0
        cdef int j = 0
        cdef int k
        for doc in docs:
            beam = Beam(nr_class, beam_width, min_density=beam_density)
            beam.initialize(self.moves.init_beam_state, doc.length, doc.c)
            for i in range(beam.width):
                stcls = <StateClass>beam.at(i)
                stcls.c.offset = offset
            offset += len(doc)
            beam.check_done(_check_final_state, NULL)
            while not beam.is_done:
                states = []
                for i in range(beam.size):
                    stcls = <StateClass>beam.at(i)
                    # This way we avoid having to score finalized states
                    # We do have to take care to keep indexes aligned, though
                    if not stcls.is_final():
                        states.append(stcls)
                token_ids = self.get_token_ids(states)
                vectors = state2vec(token_ids)
                scores = vec2scores(vectors)
                j = 0
                c_scores = <float*>scores.data
                for i in range(beam.size):
                    stcls = <StateClass>beam.at(i)
                    if not stcls.is_final():
                        self.moves.set_valid(beam.is_valid[i], stcls.c)
                        for k in range(nr_class):
                            beam.scores[i][k] = c_scores[j * scores.shape[1] + k]
                        j += 1
                beam.advance(_transition_state, _hash_state, <void*>self.moves.c)
                beam.check_done(_check_final_state, NULL)
            beams.append(beam)
        return beams

    cdef void _parse_step(self, StateC* state,
            const float* feat_weights,
            int nr_class, int nr_feat, int nr_piece) nogil:
        '''This only works with no hidden layers -- fast but inaccurate'''
        #for i in cython.parallel.prange(next_step.size(), num_threads=4, nogil=True):
        #    self._parse_step(next_step[i], feat_weights, nr_class, nr_feat)
        token_ids = <int*>calloc(nr_feat, sizeof(int))
        scores = <float*>calloc(nr_class * nr_piece, sizeof(float))
        is_valid = <int*>calloc(nr_class, sizeof(int))

        state.set_context_tokens(token_ids, nr_feat)
        sum_state_features(scores,
            feat_weights, token_ids, 1, nr_feat, nr_class * nr_piece)
        self.moves.set_valid(is_valid, state)
        guess = arg_maxout_if_valid(scores, is_valid, nr_class, nr_piece)
        action = self.moves.c[guess]
        action.do(state, action.label)

        free(is_valid)
        free(scores)
        free(token_ids)

    def update(self, docs, golds, drop=0., sgd=None, losses=None):
        if not any(self.moves.has_gold(gold) for gold in golds):
            return None
        if self.cfg.get('beam_width', 1) >= 2 and numpy.random.random() >= 0.5:
            return self.update_beam(docs, golds,
                    self.cfg['beam_width'], self.cfg['beam_density'],
                    drop=drop, sgd=sgd, losses=losses)
        if losses is not None and self.name not in losses:
            losses[self.name] = 0.
        if isinstance(docs, Doc) and isinstance(golds, GoldParse):
            docs = [docs]
            golds = [golds]

        cuda_stream = get_cuda_stream()

        states, golds, max_steps = self._init_gold_batch(docs, golds)
        (tokvecs, bp_tokvecs), state2vec, vec2scores = self.get_batch_model(docs, cuda_stream,
                                                                            0.0)
        todo = [(s, g) for (s, g) in zip(states, golds)
                if not s.is_final() and g is not None]
        if not todo:
            return None

        backprops = []
        d_tokvecs = state2vec.ops.allocate(tokvecs.shape)
        cdef float loss = 0.
        n_steps = 0
        while todo:
            states, golds = zip(*todo)

            token_ids = self.get_token_ids(states)
            vector, bp_vector = state2vec.begin_update(token_ids, drop=0.0)
            if drop != 0:
                mask = vec2scores.ops.get_dropout_mask(vector.shape, drop)
                vector *= mask
            scores, bp_scores = vec2scores.begin_update(vector, drop=drop)

            d_scores = self.get_batch_loss(states, golds, scores)
            d_scores /= len(docs)
            d_vector = bp_scores(d_scores, sgd=sgd)
            if drop != 0:
                d_vector *= mask

            if isinstance(self.model[0].ops, CupyOps) \
            and not isinstance(token_ids, state2vec.ops.xp.ndarray):
                # Move token_ids and d_vector to GPU, asynchronously
                backprops.append((
                    get_async(cuda_stream, token_ids),
                    get_async(cuda_stream, d_vector),
                    bp_vector
                ))
            else:
                backprops.append((token_ids, d_vector, bp_vector))
            self.transition_batch(states, scores)
            todo = [st for st in todo if not st[0].is_final()]
            if losses is not None:
                losses[self.name] += (d_scores**2).sum()
            n_steps += 1
            if n_steps >= max_steps:
                break
        self._make_updates(d_tokvecs,
            bp_tokvecs, backprops, sgd, cuda_stream)

    def update_beam(self, docs, golds, width=None, density=None,
            drop=0., sgd=None, losses=None):
        if not any(self.moves.has_gold(gold) for gold in golds):
            return None
        if not golds:
            return None
        if width is None:
            width = self.cfg.get('beam_width', 2)
        if density is None:
            density = self.cfg.get('beam_density', 0.0)
        if losses is not None and self.name not in losses:
            losses[self.name] = 0.
        lengths = [len(d) for d in docs]
        assert min(lengths) >= 1
        states = self.moves.init_batch(docs)
        for gold in golds:
            self.moves.preprocess_gold(gold)

        cuda_stream = get_cuda_stream()
        (tokvecs, bp_tokvecs), state2vec, vec2scores = self.get_batch_model(docs, cuda_stream, 0.0)

        states_d_scores, backprops = _beam_utils.update_beam(self.moves, self.nr_feature, 500,
                                        states, golds,
                                        state2vec, vec2scores,
                                        width, density,
                                        drop=drop, losses=losses)
        backprop_lower = []
        cdef float batch_size = len(docs)
        for i, d_scores in enumerate(states_d_scores):
            d_scores /= batch_size
            if losses is not None:
                losses[self.name] += (d_scores**2).sum()
            ids, bp_vectors, bp_scores = backprops[i]
            d_vector = bp_scores(d_scores, sgd=sgd)
            if isinstance(self.model[0].ops, CupyOps) \
            and not isinstance(ids, state2vec.ops.xp.ndarray):
                backprop_lower.append((
                    get_async(cuda_stream, ids),
                    get_async(cuda_stream, d_vector),
                    bp_vectors))
            else:
                backprop_lower.append((ids, d_vector, bp_vectors))
        d_tokvecs = self.model[0].ops.allocate(tokvecs.shape)
        self._make_updates(d_tokvecs, bp_tokvecs, backprop_lower, sgd, cuda_stream)

    def _init_gold_batch(self, whole_docs, whole_golds):
        """Make a square batch, of length equal to the shortest doc. A long
        doc will get multiple states. Let's say we have a doc of length 2*N,
        where N is the shortest doc. We'll make two states, one representing
        long_doc[:N], and another representing long_doc[N:]."""
        cdef:
            StateClass state
            Transition action
        whole_states = self.moves.init_batch(whole_docs)
        max_length = max(5, min(50, min([len(doc) for doc in whole_docs])))
        max_moves = 0
        states = []
        golds = []
        for doc, state, gold in zip(whole_docs, whole_states, whole_golds):
            gold = self.moves.preprocess_gold(gold)
            if gold is None:
                continue
            oracle_actions = self.moves.get_oracle_sequence(doc, gold)
            start = 0
            while start < len(doc):
                state = state.copy()
                n_moves = 0
                while state.B(0) < start and not state.is_final():
                    action = self.moves.c[oracle_actions.pop(0)]
                    action.do(state.c, action.label)
                    n_moves += 1
                has_gold = self.moves.has_gold(gold, start=start,
                                               end=start+max_length)
                if not state.is_final() and has_gold:
                    states.append(state)
                    golds.append(gold)
                    max_moves = max(max_moves, n_moves)
                start += min(max_length, len(doc)-start)
            max_moves = max(max_moves, len(oracle_actions))
        return states, golds, max_moves

    def _make_updates(self, d_tokvecs, bp_tokvecs, backprops, sgd, cuda_stream=None):
        # Tells CUDA to block, so our async copies complete.
        if cuda_stream is not None:
            cuda_stream.synchronize()
        xp = get_array_module(d_tokvecs)
        for ids, d_vector, bp_vector in backprops:
            d_state_features = bp_vector(d_vector, sgd=sgd)
            mask = ids >= 0
            d_state_features *= mask.reshape(ids.shape + (1,))
            self.model[0].ops.scatter_add(d_tokvecs, ids * mask,
                d_state_features)
        bp_tokvecs(d_tokvecs, sgd=sgd)

    @property
    def move_names(self):
        names = []
        for i in range(self.moves.n_moves):
            name = self.moves.move_name(self.moves.c[i].move, self.moves.c[i].label)
            names.append(name)
        return names

    def get_batch_model(self, docs, stream, dropout):
        tok2vec, lower, upper = self.model
        tokvecs, bp_tokvecs = tok2vec.begin_update(docs, drop=dropout)
        state2vec = precompute_hiddens(len(docs), tokvecs,
                        lower, stream, drop=dropout)
        return (tokvecs, bp_tokvecs), state2vec, upper

    nr_feature = 8

    def get_token_ids(self, states):
        cdef StateClass state
        cdef int n_tokens = self.nr_feature
        cdef np.ndarray ids = numpy.zeros((len(states), n_tokens),
                                          dtype='i', order='C')
        c_ids = <int*>ids.data
        for i, state in enumerate(states):
            if not state.is_final():
                state.c.set_context_tokens(c_ids, n_tokens)
            c_ids += ids.shape[1]
        return ids

    def transition_batch(self, states, float[:, ::1] scores):
        cdef StateClass state
        cdef int[500] is_valid # TODO: Unhack
        cdef float* c_scores = &scores[0, 0]
        for state in states:
            self.moves.set_valid(is_valid, state.c)
            guess = arg_max_if_valid(c_scores, is_valid, scores.shape[1])
            action = self.moves.c[guess]
            action.do(state.c, action.label)
            c_scores += scores.shape[1]

    def get_batch_loss(self, states, golds, float[:, ::1] scores):
        cdef StateClass state
        cdef GoldParse gold
        cdef Pool mem = Pool()
        cdef int i
        is_valid = <int*>mem.alloc(self.moves.n_moves, sizeof(int))
        costs = <float*>mem.alloc(self.moves.n_moves, sizeof(float))
        cdef np.ndarray d_scores = numpy.zeros((len(states), self.moves.n_moves),
                                        dtype='f', order='C')
        c_d_scores = <float*>d_scores.data
        for i, (state, gold) in enumerate(zip(states, golds)):
            memset(is_valid, 0, self.moves.n_moves * sizeof(int))
            memset(costs, 0, self.moves.n_moves * sizeof(float))
            self.moves.set_costs(is_valid, costs, state, gold)
            cpu_log_loss(c_d_scores,
                costs, is_valid, &scores[i, 0], d_scores.shape[1])
            c_d_scores += d_scores.shape[1]
        return d_scores

    def set_annotations(self, docs, states):
        cdef StateClass state
        cdef Doc doc
        for state, doc in zip(states, docs):
            self.moves.finalize_state(state.c)
            for i in range(doc.length):
                doc.c[i] = state.c._sent[i]
            self.moves.finalize_doc(doc)

    def add_label(self, label):
        for action in self.moves.action_types:
            added = self.moves.add_action(action, label)
            if added:
                # Important that the labels be stored as a list! We need the
                # order, or the model goes out of synch
                self.cfg.setdefault('extra_labels', []).append(label)

    def begin_training(self, gold_tuples, pipeline=None, **cfg):
        if 'model' in cfg:
            self.model = cfg['model']
        gold_tuples = nonproj.preprocess_training_data(gold_tuples)
        actions = self.moves.get_actions(gold_parses=gold_tuples)
        for action, labels in actions.items():
            for label in labels:
                self.moves.add_action(action, label)
        if self.model is True:
            cfg['pretrained_dims'] = self.vocab.vectors_length
            self.model, cfg = self.Model(self.moves.n_moves, **cfg)
            self.init_multitask_objectives(gold_tuples, pipeline, **cfg)
            link_vectors_to_models(self.vocab)
            self.cfg.update(cfg)

    def init_multitask_objectives(self, gold_tuples, pipeline, **cfg):
        '''Setup models for secondary objectives, to benefit from multi-task
        learning. This method is intended to be overridden by subclasses.

        For instance, the dependency parser can benefit from sharing
        an input representation with a label prediction model. These auxiliary
        models are discarded after training.
        '''
        pass

    def preprocess_gold(self, docs_golds):
        for doc, gold in docs_golds:
            yield doc, gold

    def use_params(self, params):
        # Can't decorate cdef class :(. Workaround.
        with self.model[0].use_params(params):
            with self.model[1].use_params(params):
                yield

    def to_disk(self, path, **exclude):
        serializers = {
            'tok2vec_model': lambda p: p.open('wb').write(
                self.model[0].to_bytes()),
            'lower_model': lambda p: p.open('wb').write(
                self.model[1].to_bytes()),
            'upper_model': lambda p: p.open('wb').write(
                self.model[2].to_bytes()),
            'vocab': lambda p: self.vocab.to_disk(p),
            'moves': lambda p: self.moves.to_disk(p, strings=False),
            'cfg': lambda p: p.open('w').write(json_dumps(self.cfg))
        }
        util.to_disk(path, serializers, exclude)

    def from_disk(self, path, **exclude):
        deserializers = {
            'vocab': lambda p: self.vocab.from_disk(p),
            'moves': lambda p: self.moves.from_disk(p, strings=False),
            'cfg': lambda p: self.cfg.update(ujson.load(p.open())),
            'model': lambda p: None
        }
        util.from_disk(path, deserializers, exclude)
        if 'model' not in exclude:
            path = util.ensure_path(path)
            if self.model is True:
                self.cfg['pretrained_dims'] = self.vocab.vectors_length
                self.model, cfg = self.Model(**self.cfg)
            else:
                cfg = {}
            with (path / 'tok2vec_model').open('rb') as file_:
                bytes_data = file_.read()
            self.model[0].from_bytes(bytes_data)
            with (path / 'lower_model').open('rb') as file_:
                bytes_data = file_.read()
            self.model[1].from_bytes(bytes_data)
            with (path / 'upper_model').open('rb') as file_:
                bytes_data = file_.read()
            self.model[2].from_bytes(bytes_data)
            self.cfg.update(cfg)
        return self

    def to_bytes(self, **exclude):
        serializers = OrderedDict((
            ('tok2vec_model', lambda: self.model[0].to_bytes()),
            ('lower_model', lambda: self.model[1].to_bytes()),
            ('upper_model', lambda: self.model[2].to_bytes()),
            ('vocab', lambda: self.vocab.to_bytes()),
            ('moves', lambda: self.moves.to_bytes(strings=False)),
            ('cfg', lambda: json.dumps(self.cfg, indent=2, sort_keys=True))
        ))
        if 'model' in exclude:
            exclude['tok2vec_model'] = True
            exclude['lower_model'] = True
            exclude['upper_model'] = True
            exclude.pop('model')
        return util.to_bytes(serializers, exclude)

    def from_bytes(self, bytes_data, **exclude):
        deserializers = OrderedDict((
            ('vocab', lambda b: self.vocab.from_bytes(b)),
            ('moves', lambda b: self.moves.from_bytes(b, strings=False)),
            ('cfg', lambda b: self.cfg.update(json.loads(b))),
            ('tok2vec_model', lambda b: None),
            ('lower_model', lambda b: None),
            ('upper_model', lambda b: None)
        ))
        msg = util.from_bytes(bytes_data, deserializers, exclude)
        if 'model' not in exclude:
            if self.model is True:
                self.model, cfg = self.Model(**self.cfg)
                cfg['pretrained_dims'] = self.vocab.vectors_length
            else:
                cfg = {}
            cfg['pretrained_dims'] = self.vocab.vectors_length
            if 'tok2vec_model' in msg:
                self.model[0].from_bytes(msg['tok2vec_model'])
            if 'lower_model' in msg:
                self.model[1].from_bytes(msg['lower_model'])
            if 'upper_model' in msg:
                self.model[2].from_bytes(msg['upper_model'])
            self.cfg.update(cfg)
        return self


class ParserStateError(ValueError):
    def __init__(self, doc):
        ValueError.__init__(self,
            "Error analysing doc -- no valid actions available. This should "
            "never happen, so please report the error on the issue tracker. "
            "Here's the thread to do so --- reopen it if it's closed:\n"
            "https://github.com/spacy-io/spaCy/issues/429\n"
            "Please include the text that the parser failed on, which is:\n"
            "%s" % repr(doc.text))


cdef int arg_max_if_gold(const weight_t* scores, const weight_t* costs, const int* is_valid, int n) nogil:
    # Find minimum cost
    cdef float cost = 1
    for i in range(n):
        if is_valid[i] and costs[i] < cost:
            cost = costs[i]
    # Now find best-scoring with that cost
    cdef int best = -1
    for i in range(n):
        if costs[i] <= cost and is_valid[i]:
            if best == -1 or scores[i] > scores[best]:
                best = i
    return best


cdef int arg_max_if_valid(const weight_t* scores, const int* is_valid, int n) nogil:
    cdef int best = -1
    for i in range(n):
        if is_valid[i] >= 1:
            if best == -1 or scores[i] > scores[best]:
                best = i
    return best


cdef int arg_maxout_if_valid(const weight_t* scores, const int* is_valid,
                             int n, int nP) nogil:
    cdef int best = -1
    cdef float best_score = 0
    for i in range(n):
        if is_valid[i] >= 1:
            for j in range(nP):
                if best == -1 or scores[i*nP+j] > best_score:
                    best = i
                    best_score = scores[i*nP+j]
    return best


cdef int _arg_max_clas(const weight_t* scores, int move, const Transition* actions,
                       int nr_class) except -1:
    cdef weight_t score = 0
    cdef int mode = -1
    cdef int i
    for i in range(nr_class):
        if actions[i].move == move and (mode == -1 or scores[i] >= score):
            mode = i
            score = scores[i]
    return mode


# These are passed as callbacks to thinc.search.Beam
cdef int _transition_state(void* _dest, void* _src, class_t clas, void* _moves) except -1:
    dest = <StateClass>_dest
    src = <StateClass>_src
    moves = <const Transition*>_moves
    dest.clone(src)
    moves[clas].do(dest.c, moves[clas].label)


cdef int _check_final_state(void* _state, void* extra_args) except -1:
    return (<StateClass>_state).is_final()


def _cleanup(Beam beam):
    for i in range(beam.width):
        Py_XDECREF(<PyObject*>beam._states[i].content)
        Py_XDECREF(<PyObject*>beam._parents[i].content)


cdef hash_t _hash_state(void* _state, void* _) except 0:
    state = <StateClass>_state
    if state.c.is_final():
        return 1
    else:
        return state.c.hash()