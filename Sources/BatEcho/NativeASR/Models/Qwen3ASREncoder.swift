// SPDX-License-Identifier: MIT
// Adapted from mlx-audio-swift, revision 3e978558404df4ad1bbb0a5634a03df2b0f9dfa5.
// Copyright (c) 2025 Prince Canuma. See ASRResources/ThirdPartyNotices.txt.
import Foundation
import MLX
import MLXNN
import MLXFast

final class Qwen3ASRSinusoidalPE {
    let _positionalEmbedding: MLXArray

    init(length: Int, channels: Int, maxTimescale: Float = 10000.0) {
        precondition(channels % 2 == 0, "SinusoidalPE channels must be even")

        let logTimescaleIncrement = log(maxTimescale) / Float(channels / 2 - 1)
        let invTimescales = MLX.exp(
            -logTimescaleIncrement * MLXArray(0..<(channels / 2)).asType(.float32)
        )
        let positions = MLXArray(0..<length).asType(.float32).reshaped(-1, 1)
        let scaledTime = positions * invTimescales.reshaped(1, -1)
        self._positionalEmbedding = MLX.concatenated(
            [MLX.sin(scaledTime), MLX.cos(scaledTime)], axis: 1
        )
    }

    func callAsFunction(_ seqLen: Int) -> MLXArray {
        return _positionalEmbedding[0..<seqLen]
    }
}

// MARK: - Audio Encoder Attention

class Qwen3ASRAttention: Module {
    let embedDim: Int
    let numHeads: Int
    let headDim: Int
    let scaling: Float

    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "out_proj") var outProj: Linear

    init(_ config: Qwen3AudioEncoderConfig) {
        self.embedDim = config.dModel
        self.numHeads = config.encoderAttentionHeads
        self.headDim = embedDim / numHeads
        self.scaling = pow(Float(headDim), -0.5)

        precondition(headDim * numHeads == embedDim,
            "embed_dim must be divisible by num_heads")

        self._qProj.wrappedValue = Linear(embedDim, embedDim, bias: true)
        self._kProj.wrappedValue = Linear(embedDim, embedDim, bias: true)
        self._vProj.wrappedValue = Linear(embedDim, embedDim, bias: true)
        self._outProj.wrappedValue = Linear(embedDim, embedDim, bias: true)
    }

    func callAsFunction(_ hiddenStates: MLXArray, mask: MLXArray? = nil) -> MLXArray {
        let B = hiddenStates.dim(0)
        let L = hiddenStates.dim(1)

        var queries = qProj(hiddenStates)
        var keys = kProj(hiddenStates)
        var values = vProj(hiddenStates)

        queries = queries.reshaped(B, L, numHeads, headDim).transposed(0, 2, 1, 3)
        keys = keys.reshaped(B, L, numHeads, headDim).transposed(0, 2, 1, 3)
        values = values.reshaped(B, L, numHeads, headDim).transposed(0, 2, 1, 3)

        let maskMode: MLXFast.ScaledDotProductAttentionMaskMode = mask != nil ? .array(mask!) : .none
        let attnOutput = MLXFast.scaledDotProductAttention(
            queries: queries,
            keys: keys,
            values: values,
            scale: scaling,
            mask: maskMode
        )

        let output = attnOutput.transposed(0, 2, 1, 3).reshaped(B, L, embedDim)
        return outProj(output)
    }
}

// MARK: - Audio Encoder Layer

class Qwen3ASRAudioEncoderLayer: Module {
    let embedDim: Int

    @ModuleInfo(key: "self_attn") var selfAttn: Qwen3ASRAttention
    @ModuleInfo(key: "self_attn_layer_norm") var selfAttnLayerNorm: LayerNorm
    @ModuleInfo(key: "fc1") var fc1: Linear
    @ModuleInfo(key: "fc2") var fc2: Linear
    @ModuleInfo(key: "final_layer_norm") var finalLayerNorm: LayerNorm

    init(_ config: Qwen3AudioEncoderConfig) {
        self.embedDim = config.dModel

        self._selfAttn.wrappedValue = Qwen3ASRAttention(config)
        self._selfAttnLayerNorm.wrappedValue = LayerNorm(dimensions: embedDim)
        self._fc1.wrappedValue = Linear(embedDim, config.encoderFfnDim)
        self._fc2.wrappedValue = Linear(config.encoderFfnDim, embedDim)
        self._finalLayerNorm.wrappedValue = LayerNorm(dimensions: embedDim)
    }

    func callAsFunction(_ hiddenStates: MLXArray, mask: MLXArray? = nil) -> MLXArray {
        // Pre-norm attention
        var residual = hiddenStates
        var h = selfAttnLayerNorm(hiddenStates)
        h = selfAttn(h, mask: mask)
        h = residual + h

        // Pre-norm FFN
        residual = h
        h = finalLayerNorm(h)
        h = gelu(fc1(h))
        h = fc2(h)
        h = residual + h

        return h
    }
}

// MARK: - Audio Encoder

class Qwen3ASRAudioEncoder: Module {
    let config: Qwen3AudioEncoderConfig
    let nWindow: Int
    let nWindowInfer: Int

    @ModuleInfo(key: "conv2d1") var conv2d1: Conv2d
    @ModuleInfo(key: "conv2d2") var conv2d2: Conv2d
    @ModuleInfo(key: "conv2d3") var conv2d3: Conv2d
    @ModuleInfo(key: "conv_out") var convOut: Linear
    @ModuleInfo(key: "layers") var layers: [Qwen3ASRAudioEncoderLayer]
    @ModuleInfo(key: "ln_post") var lnPost: LayerNorm
    @ModuleInfo(key: "proj1") var proj1: Linear
    @ModuleInfo(key: "proj2") var proj2: Linear

    let positionalEmbedding: Qwen3ASRSinusoidalPE

    init(_ config: Qwen3AudioEncoderConfig) {
        self.config = config
        let embedDim = config.dModel
        self.nWindow = config.nWindow
        self.nWindowInfer = config.nWindowInfer

        // Conv2d frontend: input is [batch, mel_bins, time, 1]
        self._conv2d1.wrappedValue = Conv2d(
            inputChannels: 1,
            outputChannels: config.downsampleHiddenSize,
            kernelSize: 3,
            stride: 2,
            padding: 1
        )
        self._conv2d2.wrappedValue = Conv2d(
            inputChannels: config.downsampleHiddenSize,
            outputChannels: config.downsampleHiddenSize,
            kernelSize: 3,
            stride: 2,
            padding: 1
        )
        self._conv2d3.wrappedValue = Conv2d(
            inputChannels: config.downsampleHiddenSize,
            outputChannels: config.downsampleHiddenSize,
            kernelSize: 3,
            stride: 2,
            padding: 1
        )

        // Frequency dimension after 3 conv layers with stride 2
        let freqAfterConv = ((((config.numMelBins + 1) / 2) + 1) / 2 + 1) / 2
        self._convOut.wrappedValue = Linear(
            config.downsampleHiddenSize * freqAfterConv, embedDim, bias: false
        )

        self.positionalEmbedding = Qwen3ASRSinusoidalPE(
            length: config.maxSourcePositions, channels: embedDim
        )

        self._layers.wrappedValue = (0..<config.encoderLayers).map { _ in
            Qwen3ASRAudioEncoderLayer(config)
        }
        self._lnPost.wrappedValue = LayerNorm(dimensions: embedDim)
        self._proj1.wrappedValue = Linear(embedDim, embedDim)
        self._proj2.wrappedValue = Linear(embedDim, config.outputDim)
    }

    func encodeSingleWindow(_ melFrames: MLXArray, check: () throws -> Void) throws -> MLXArray {
        let numFrames = melFrames.dim(0)
        let chunkSize = nWindow * 2  // 100 mel frames per conv chunk

        // Split into conv-sized chunks
        let numChunks = Int(ceil(Double(numFrames) / Double(chunkSize)))
        var chunks: [MLXArray] = []
        var chunkLengths: [Int] = []

        for j in 0..<numChunks {
            let start = j * chunkSize
            let end = min(start + chunkSize, numFrames)
            let chunk = melFrames[start..<end]  // [clen, nMels]
            let transposed = chunk.transposed(1, 0)  // [nMels, clen]
            chunks.append(transposed)
            chunkLengths.append(end - start)
        }

        let maxChunkLen = chunkLengths.max() ?? 0

        // Pad chunks to same length
        var paddedChunks: [MLXArray] = []
        for (idx, chunk) in chunks.enumerated() {
            let clen = chunkLengths[idx]
            if clen < maxChunkLen {
                let padWidth = maxChunkLen - clen
                let padded = MLX.padded(chunk, widths: [IntOrPair((0, 0)), IntOrPair((0, padWidth))])
                paddedChunks.append(padded)
            } else {
                paddedChunks.append(chunk)
            }
        }

        // Compute output lengths after CNN
        let featureLensAfterCnnValues = chunkLengths.map { ($0 + 7) / 8 }

        // Conv2d frontend: [batch, nMels, time, 1]
        var x = MLX.stacked(paddedChunks, axis: 0).expandedDimensions(axis: -1)
        x = gelu(conv2d1(x))
        x = gelu(conv2d2(x))
        x = gelu(conv2d3(x))

        let f = x.dim(1)
        let t = x.dim(2)
        let c = x.dim(3)
        x = x.transposed(0, 2, 3, 1).reshaped(numChunks, t, c * f)
        x = convOut(x)

        let posEmb = positionalEmbedding(x.dim(1))
        x = x + posEmb.asType(x.dtype).expandedDimensions(axis: 0)
        eval(x)

        // Extract valid-length hidden states
        var hiddenList: [MLXArray] = []
        for i in 0..<numChunks {
            let validLen = featureLensAfterCnnValues[i]
            hiddenList.append(x[i, 0..<validLen])
        }

        // Concatenate all chunks into a single sequence
        var hiddenStates = MLX.concatenated(hiddenList, axis: 0)  // [totalTokens, dModel]

        // Self-attention across the full window (no cross-window mask needed)
        hiddenStates = hiddenStates.expandedDimensions(axis: 0)  // [1, totalTokens, dModel]
        for layer in layers {
            try check()
            hiddenStates = layer(hiddenStates, mask: nil)
            eval(hiddenStates)
        }
        eval(hiddenStates)

        hiddenStates = hiddenStates.squeezed(axis: 0)  // [totalTokens, dModel]

        // Post-processing
        hiddenStates = lnPost(hiddenStates)
        hiddenStates = gelu(proj1(hiddenStates))
        hiddenStates = proj2(hiddenStates)

        return hiddenStates  // [numTokens, outputDim]
    }
}
