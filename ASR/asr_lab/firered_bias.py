# SPDX-License-Identifier: MIT
# Beam-search portions adapted from mlx-audio 0.5.4 (MIT).
# Upstream: https://github.com/Blaizzy/mlx-audio
# License: ../third_party/mlx-audio-LICENSE
"""FireRed AED contextual beam search; acoustic confidence stays unboosted."""
import time

import mlx.core as mx
import numpy as np
from mlx_audio.stt.models.base import STTOutput


def biased_beam_search(decoder, enc_output, graph, *, beam_size=3,max_len=128,
                       softmax_smoothing=1.25,length_penalty=0.6,eos_penalty=1.0):
    count = beam_size
    enc_expanded = mx.repeat(enc_output,count,axis=0)
    ys = mx.full((count,1),decoder.sos_id,dtype=mx.int32)
    scores = mx.array([0.0]+[-1e10]*(count-1)).reshape(count,1)
    finished = mx.zeros((count,1))
    states = [0]*count
    seen = [0]*count
    caches = [None]*decoder.n_layers
    confidences = mx.zeros((count,1))
    for _ in range(max_len if max_len > 0 else enc_output.shape[1]):
        length = ys.shape[1]
        causal = mx.expand_dims(mx.tril(mx.ones((length,length))),axis=0)
        hidden = decoder.tgt_word_emb(ys)*decoder.scale+decoder.positional_encoding(length)
        next_caches = []
        for i,layer in enumerate(decoder.layer_stack):
            hidden = layer(hidden,enc_expanded,causal,cache=caches[i])
            next_caches.append(hidden)
        logits = decoder.tgt_word_prj(decoder.layer_norm_out(hidden)[:,-1,:])
        acoustic = mx.log(mx.softmax(logits/softmax_smoothing,axis=-1)+1e-10)
        token_scores = acoustic
        if eos_penalty != 1.0:
            token_scores = mx.concatenate([
                token_scores[:,:decoder.eos_id],
                token_scores[:,decoder.eos_id:decoder.eos_id+1]*eos_penalty,
                token_scores[:,decoder.eos_id+1:],
            ],axis=-1)
        # Bias before pruning: a rare word's first token must be able to survive.
        rewards = mx.array(np.stack([graph.reward_vector(state,used) for state,used in zip(states,seen)]))
        token_scores = token_scores+rewards
        top_scores,top_ids = decoder._topk(token_scores,count)
        top_acoustic = mx.take_along_axis(acoustic,top_ids,axis=-1)
        mask = mx.repeat(mx.array([0.0]+[-1e10]*(count-1)).reshape(1,count),count,axis=0)
        top_scores = top_scores*(1-finished)+mask*finished
        top_ids = top_ids*(1-finished.astype(mx.int32))+decoder.eos_id*finished.astype(mx.int32)
        top_acoustic = top_acoustic*(1-finished)
        best_scores,best_idx = decoder._topk((scores+top_scores).reshape(1,count*count),count)
        scores = best_scores.reshape(count,1)
        parent = (best_idx.reshape(count)//count).astype(mx.int32)
        tokens = top_ids.reshape(count*count)[best_idx.reshape(count)]
        ys = mx.concatenate([ys[parent],tokens[:,None]],axis=1)
        confidences = mx.concatenate([
            confidences[parent],
            mx.exp(top_acoustic.reshape(count*count)[best_idx.reshape(count)])[:,None],
        ],axis=1)
        parents = parent.tolist()
        selected_tokens = tokens.tolist()
        next_states,next_seen = [],[]
        for old,token in zip(parents,selected_tokens):
            state,_,used = graph.step(states[old],token,seen[old])
            next_states.append(state)
            next_seen.append(used)
        states,seen = next_states,next_seen
        caches = [cache[parent] for cache in next_caches]
        finished = (tokens[:,None]==decoder.eos_id).astype(mx.float32)
        mx.eval(finished)
        if finished.sum().item() == count:
            break
    # Refund any prefix still active at max_len, including incomplete words.
    refunds = mx.array([graph.finalize(state,used) for state,used in zip(states,seen)])[:,None]
    final_scores = scores+refunds
    lengths = mx.sum(ys!=decoder.eos_id,axis=-1,keepdims=True).astype(mx.float32)
    if length_penalty > 0:
        final_scores = final_scores/mx.power((5+lengths)/6,length_penalty)
    best = mx.argmax(final_scores.reshape(-1)).item()
    return ys[best,1:],confidences[best,1:]


def generate_with_hotwords(model,audio,graph,decode_options):
    started = time.perf_counter()
    features = model._extract_fbank(audio)
    if model._cmvn is not None:
        means,istd = model._cmvn
        features = (features-means)*istd
    features = mx.expand_dims(features,axis=0)
    mx.eval(features)
    encoded = model.encoder(features)
    mx.eval(encoded)
    sequence,confidence = biased_beam_search(model.decoder,encoded,graph,**decode_options)
    mx.eval(sequence,confidence)
    ids = sequence.tolist()
    if model.config.eos_id in ids:
        ids = ids[:ids.index(model.config.eos_id)]
    text = model._detokenize(ids)
    score = float(mx.mean(confidence[:len(ids)]).item()) if ids else 0.0
    return STTOutput(text=text,segments=[{"text":text,"confidence":round(score,3)}],
                     total_time=time.perf_counter()-started,generation_tokens=len(ids))
