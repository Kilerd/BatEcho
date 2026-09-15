// SPDX-License-Identifier: MIT
// Adapted from mlx-audio 0.5.4 and voicer's Python contextual decoder.
// Copyright (c) 2025 Prince Canuma. See ASRResources/ThirdPartyNotices.txt.
import Foundation
import MLX

enum ContextualBeamSearch {
    static func decode(encoderOutput: MLXArray, decoder: FireRedASR2TransformerDecoder,
                       graph: HotwordGraph?, beamSize: Int, maxLen: Int,
                       smoothing: Float, lengthPenalty: Float, eosPenalty: Float,
                       check: () throws -> Void) throws -> ([Int32], [Float]) {
        let count = beamSize
        let expanded = repeated(encoderOutput, count: count, axis: 0)
        var tokens = MLX.full([count, 1], values: Int32(decoder.sosID), type: Int32.self)
        var scores = MLXArray([Float(0)] + Array(repeating: Float(-1e10), count: count - 1)).reshaped([count, 1])
        var finished = MLXArray.zeros([count, 1])
        var states = Array(repeating: HotwordGraph.State(), count: count)
        var caches = Array<MLXArray?>(repeating: nil, count: decoder.nLayers)
        var confidence = MLXArray.zeros([count, 1])
        let mask = repeated(MLXArray([Float(0)] + Array(repeating: Float(-1e10), count: count - 1))
            .reshaped([1, count]), count: count, axis: 0)
        for _ in 0..<maxLen {
            try check()
            let (logits, nextCaches) = decoder.decodeOneStep(tokens, encoderOutput: expanded, cache: caches)
            let acoustic = log(softmax(logits / smoothing, axis: -1) + Float(1e-10))
            var biased = acoustic
            if eosPenalty != 1 {
                biased = concatenated([acoustic[0..., 0..<decoder.eosID],
                                       acoustic[0..., decoder.eosID..<(decoder.eosID + 1)] * eosPenalty,
                                       acoustic[0..., (decoder.eosID + 1)...]], axis: 1)
            }
            // Apply bias before top-k so rare prefixes can survive beam pruning.
            if let graph {
                biased = biased + MLXArray(states.flatMap { graph.rewards($0) }).reshaped(acoustic.shape)
            }
            var (topScores, topTokens) = FireRedASR2TransformerDecoder.topK(biased, k: count)
            var topAcoustic = takeAlong(acoustic, topTokens, axis: -1)
            topScores = topScores * (1 - finished) + mask * finished
            let finishedInt = finished.asType(.int32)
            let unfinishedInt = MLXArray(Int32(1)) - finishedInt
            let liveTokens = topTokens.asType(.int32) * unfinishedInt
            let eosTokens = MLXArray(Int32(decoder.eosID)) * finishedInt
            topTokens = liveTokens + eosTokens
            topAcoustic = topAcoustic * (1 - finished)
            let (chosenScores, indices) = FireRedASR2TransformerDecoder.topK((scores + topScores).reshaped([1, count * count]), k: count)
            scores = chosenScores.reshaped([count, 1])
            let selected = indices.reshaped([count]).asType(.int32)
            let parents = (selected / Int32(count)).asType(.int32)
            let nextTokens = take(topTokens.reshaped([-1]), selected)
            tokens = concatenated([take(tokens, parents, axis: 0), nextTokens.reshaped([count, 1])], axis: 1)
            confidence = concatenated([take(confidence, parents, axis: 0),
                                       exp(take(topAcoustic.reshaped([-1]), selected)).reshaped([count, 1])], axis: 1)
            caches = nextCaches.map { $0.map { take($0, parents, axis: 0) } }
            if let graph {
                let parentValues = parents.asArray(Int32.self)
                let tokenValues = nextTokens.asArray(Int32.self)
                states = zip(parentValues, tokenValues).map { graph.step(states[Int($0)], token: Int($1)).0 }
            }
            finished = (nextTokens .== Int32(decoder.eosID)).asType(.float32).reshaped([count, 1])
            eval(finished)
            try check()
            if finished.sum().item(Float.self) == Float(count) { break }
        }
        var finalScores = scores
        if let graph { finalScores = finalScores + MLXArray(states.map { graph.finalize($0) }).reshaped([count, 1]) }
        if lengthPenalty > 0 {
            let lengths = (tokens .!= Int32(decoder.eosID)).sum(axis: -1, keepDims: true).asType(.float32)
            finalScores = finalScores / pow((5 + lengths) / 6, lengthPenalty)
        }
        let best = argMax(finalScores.reshaped([-1])).item(Int.self)
        return (tokens[best, 1...].asArray(Int32.self), confidence[best, 1...].asArray(Float.self))
    }
}
