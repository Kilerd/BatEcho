// SPDX-License-Identifier: MIT
// Adapted from mlx-audio-swift, revision 3e978558404df4ad1bbb0a5634a03df2b0f9dfa5.
// Copyright (c) 2025 Prince Canuma. See ASRResources/ThirdPartyNotices.txt.
//
//  Qwen3ASRConfig.swift
//  MLXAudioSTT
//
// Created by Prince Canuma on 06/02/2026.
//

import Foundation

// MARK: - Audio Encoder Config

struct Qwen3AudioEncoderConfig: Codable {
    var numMelBins: Int
    var encoderLayers: Int
    var encoderAttentionHeads: Int
    var encoderFfnDim: Int
    var dModel: Int
    var dropout: Float
    var attentionDropout: Float
    var activationFunction: String
    var activationDropout: Float
    var scaleEmbedding: Bool
    var maxSourcePositions: Int
    var nWindow: Int
    var outputDim: Int
    var nWindowInfer: Int
    var convChunksize: Int
    var downsampleHiddenSize: Int

    enum CodingKeys: String, CodingKey {
        case numMelBins = "num_mel_bins"
        case encoderLayers = "encoder_layers"
        case encoderAttentionHeads = "encoder_attention_heads"
        case encoderFfnDim = "encoder_ffn_dim"
        case dModel = "d_model"
        case dropout
        case attentionDropout = "attention_dropout"
        case activationFunction = "activation_function"
        case activationDropout = "activation_dropout"
        case scaleEmbedding = "scale_embedding"
        case maxSourcePositions = "max_source_positions"
        case nWindow = "n_window"
        case outputDim = "output_dim"
        case nWindowInfer = "n_window_infer"
        case convChunksize = "conv_chunksize"
        case downsampleHiddenSize = "downsample_hidden_size"
    }

    init(
        numMelBins: Int = 128,
        encoderLayers: Int = 24,
        encoderAttentionHeads: Int = 16,
        encoderFfnDim: Int = 4096,
        dModel: Int = 1024,
        dropout: Float = 0.0,
        attentionDropout: Float = 0.0,
        activationFunction: String = "gelu",
        activationDropout: Float = 0.0,
        scaleEmbedding: Bool = false,
        maxSourcePositions: Int = 1500,
        nWindow: Int = 50,
        outputDim: Int = 2048,
        nWindowInfer: Int = 800,
        convChunksize: Int = 500,
        downsampleHiddenSize: Int = 480
    ) {
        self.numMelBins = numMelBins
        self.encoderLayers = encoderLayers
        self.encoderAttentionHeads = encoderAttentionHeads
        self.encoderFfnDim = encoderFfnDim
        self.dModel = dModel
        self.dropout = dropout
        self.attentionDropout = attentionDropout
        self.activationFunction = activationFunction
        self.activationDropout = activationDropout
        self.scaleEmbedding = scaleEmbedding
        self.maxSourcePositions = maxSourcePositions
        self.nWindow = nWindow
        self.outputDim = outputDim
        self.nWindowInfer = nWindowInfer
        self.convChunksize = convChunksize
        self.downsampleHiddenSize = downsampleHiddenSize
    }

    init(from decoder: Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        numMelBins = try container.decodeIfPresent(Int.self, forKey: .numMelBins) ?? 128
        encoderLayers = try container.decodeIfPresent(Int.self, forKey: .encoderLayers) ?? 24
        encoderAttentionHeads = try container.decodeIfPresent(Int.self, forKey: .encoderAttentionHeads) ?? 16
        encoderFfnDim = try container.decodeIfPresent(Int.self, forKey: .encoderFfnDim) ?? 4096
        dModel = try container.decodeIfPresent(Int.self, forKey: .dModel) ?? 1024
        dropout = try container.decodeIfPresent(Float.self, forKey: .dropout) ?? 0.0
        attentionDropout = try container.decodeIfPresent(Float.self, forKey: .attentionDropout) ?? 0.0
        activationFunction = try container.decodeIfPresent(String.self, forKey: .activationFunction) ?? "gelu"
        activationDropout = try container.decodeIfPresent(Float.self, forKey: .activationDropout) ?? 0.0
        scaleEmbedding = try container.decodeIfPresent(Bool.self, forKey: .scaleEmbedding) ?? false
        maxSourcePositions = try container.decodeIfPresent(Int.self, forKey: .maxSourcePositions) ?? 1500
        nWindow = try container.decodeIfPresent(Int.self, forKey: .nWindow) ?? 50
        outputDim = try container.decodeIfPresent(Int.self, forKey: .outputDim) ?? 2048
        nWindowInfer = try container.decodeIfPresent(Int.self, forKey: .nWindowInfer) ?? 800
        convChunksize = try container.decodeIfPresent(Int.self, forKey: .convChunksize) ?? 500
        downsampleHiddenSize = try container.decodeIfPresent(Int.self, forKey: .downsampleHiddenSize) ?? 480
    }
}

// MARK: - Text Config

struct Qwen3TextConfig: Codable {
    var modelType: String
    var vocabSize: Int
    var hiddenSize: Int
    var intermediateSize: Int
    var numHiddenLayers: Int
    var numAttentionHeads: Int
    var numKeyValueHeads: Int
    var headDim: Int
    var hiddenAct: String
    var maxPositionEmbeddings: Int
    var rmsNormEps: Float
    var useCache: Bool
    var tieWordEmbeddings: Bool
    var ropeTheta: Float
    var ropeScaling: [String: StringAnyCodable]?
    var attentionBias: Bool
    var attentionDropout: Float

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case vocabSize = "vocab_size"
        case hiddenSize = "hidden_size"
        case intermediateSize = "intermediate_size"
        case numHiddenLayers = "num_hidden_layers"
        case numAttentionHeads = "num_attention_heads"
        case numKeyValueHeads = "num_key_value_heads"
        case headDim = "head_dim"
        case hiddenAct = "hidden_act"
        case maxPositionEmbeddings = "max_position_embeddings"
        case rmsNormEps = "rms_norm_eps"
        case useCache = "use_cache"
        case tieWordEmbeddings = "tie_word_embeddings"
        case ropeTheta = "rope_theta"
        case ropeScaling = "rope_scaling"
        case attentionBias = "attention_bias"
        case attentionDropout = "attention_dropout"
    }

    init(
        modelType: String = "qwen3",
        vocabSize: Int = 151936,
        hiddenSize: Int = 1024,
        intermediateSize: Int = 3072,
        numHiddenLayers: Int = 28,
        numAttentionHeads: Int = 16,
        numKeyValueHeads: Int = 8,
        headDim: Int = 128,
        hiddenAct: String = "silu",
        maxPositionEmbeddings: Int = 65536,
        rmsNormEps: Float = 1e-6,
        useCache: Bool = true,
        tieWordEmbeddings: Bool = true,
        ropeTheta: Float = 1000000.0,
        ropeScaling: [String: StringAnyCodable]? = nil,
        attentionBias: Bool = false,
        attentionDropout: Float = 0.0
    ) {
        self.modelType = modelType
        self.vocabSize = vocabSize
        self.hiddenSize = hiddenSize
        self.intermediateSize = intermediateSize
        self.numHiddenLayers = numHiddenLayers
        self.numAttentionHeads = numAttentionHeads
        self.numKeyValueHeads = numKeyValueHeads
        self.headDim = headDim
        self.hiddenAct = hiddenAct
        self.maxPositionEmbeddings = maxPositionEmbeddings
        self.rmsNormEps = rmsNormEps
        self.useCache = useCache
        self.tieWordEmbeddings = tieWordEmbeddings
        self.ropeTheta = ropeTheta
        self.ropeScaling = ropeScaling
        self.attentionBias = attentionBias
        self.attentionDropout = attentionDropout
    }

    init(from decoder: Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelType = try container.decodeIfPresent(String.self, forKey: .modelType) ?? "qwen3"
        vocabSize = try container.decodeIfPresent(Int.self, forKey: .vocabSize) ?? 151936
        hiddenSize = try container.decodeIfPresent(Int.self, forKey: .hiddenSize) ?? 1024
        intermediateSize = try container.decodeIfPresent(Int.self, forKey: .intermediateSize) ?? 3072
        numHiddenLayers = try container.decodeIfPresent(Int.self, forKey: .numHiddenLayers) ?? 28
        numAttentionHeads = try container.decodeIfPresent(Int.self, forKey: .numAttentionHeads) ?? 16
        numKeyValueHeads = try container.decodeIfPresent(Int.self, forKey: .numKeyValueHeads) ?? 8
        headDim = try container.decodeIfPresent(Int.self, forKey: .headDim) ?? 128
        hiddenAct = try container.decodeIfPresent(String.self, forKey: .hiddenAct) ?? "silu"
        maxPositionEmbeddings = try container.decodeIfPresent(Int.self, forKey: .maxPositionEmbeddings) ?? 65536
        rmsNormEps = try container.decodeIfPresent(Float.self, forKey: .rmsNormEps) ?? 1e-6
        useCache = try container.decodeIfPresent(Bool.self, forKey: .useCache) ?? true
        tieWordEmbeddings = try container.decodeIfPresent(Bool.self, forKey: .tieWordEmbeddings) ?? true
        ropeTheta = try container.decodeIfPresent(Float.self, forKey: .ropeTheta) ?? 1000000.0
        ropeScaling = try container.decodeIfPresent([String: StringAnyCodable].self, forKey: .ropeScaling)
        attentionBias = try container.decodeIfPresent(Bool.self, forKey: .attentionBias) ?? false
        attentionDropout = try container.decodeIfPresent(Float.self, forKey: .attentionDropout) ?? 0.0
    }
}

// MARK: - Helper for arbitrary JSON values

struct StringAnyCodable: Codable, Sendable {
    let value: AnyCodableValue

    enum AnyCodableValue: Sendable {
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case array([StringAnyCodable])
        case dictionary([String: StringAnyCodable])
        case null
    }

    init(_ value: Any) {
        switch value {
        case let b as Bool:
            self.value = .bool(b)
        case let i as Int:
            self.value = .int(i)
        case let d as Double:
            self.value = .double(d)
        case let s as String:
            self.value = .string(s)
        default:
            self.value = .null
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let bool = try? container.decode(Bool.self) {
            value = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            value = .int(int)
        } else if let double = try? container.decode(Double.self) {
            value = .double(double)
        } else if let string = try? container.decode(String.self) {
            value = .string(string)
        } else if let array = try? container.decode([StringAnyCodable].self) {
            value = .array(array)
        } else if let dictionary = try? container.decode([String: StringAnyCodable].self) {
            value = .dictionary(dictionary)
        } else {
            value = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case .bool(let b):
            try container.encode(b)
        case .int(let i):
            try container.encode(i)
        case .double(let d):
            try container.encode(d)
        case .string(let s):
            try container.encode(s)
        case .array(let a):
            try container.encode(a)
        case .dictionary(let d):
            try container.encode(d)
        case .null:
            try container.encodeNil()
        }
    }
}
