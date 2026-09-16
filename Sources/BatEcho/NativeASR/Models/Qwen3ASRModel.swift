// SPDX-License-Identifier: MIT
// Qwen architecture adapted from mlx-audio-swift; native loading and generation
// integration for BatEcho. See ASRResources/ThirdPartyNotices.txt.
import Foundation
import MLX
import MLXNN

struct QwenModelConfig: Decodable {
    struct Thinker: Decodable {
        let audioConfig: Qwen3AudioEncoderConfig
        let textConfig: Qwen3TextConfig
        let audioTokenID: Int
        let audioStartTokenID: Int
        let audioEndTokenID: Int
        enum CodingKeys: String, CodingKey {
            case audioConfig = "audio_config", textConfig = "text_config"
            case audioTokenID = "audio_token_id", audioStartTokenID = "audio_start_token_id", audioEndTokenID = "audio_end_token_id"
        }
    }
    struct Quantization: Decodable {
        let groupSize: Int
        let bits: Int
        let mode: String
        enum CodingKeys: String, CodingKey { case groupSize = "group_size", bits, mode }
    }
    let modelType: String
    let thinker: Thinker
    let quantization: Quantization?
    enum CodingKeys: String, CodingKey { case modelType = "model_type", thinker = "thinker_config", quantization }

    func validate() throws {
        let a = thinker.audioConfig, t = thinker.textConfig
        guard modelType == "qwen3_asr", thinker.audioTokenID == 151676,
              thinker.audioStartTokenID == 151669, thinker.audioEndTokenID == 151670,
              a.numMelBins == 128, a.dModel == 896, a.encoderLayers == 18,
              a.encoderAttentionHeads == 14, a.encoderFfnDim == 3584, a.outputDim == 1024,
              a.nWindow == 50, a.nWindowInfer == 800, a.downsampleHiddenSize == 480,
              a.maxSourcePositions == 1500, a.activationFunction == "gelu",
              t.hiddenSize == 1024, t.intermediateSize == 3072, t.numHiddenLayers == 28,
              t.numAttentionHeads == 16, t.numKeyValueHeads == 8, t.headDim == 128,
              t.vocabSize == 151936, t.tieWordEmbeddings, !t.attentionBias, t.hiddenAct == "silu",
              t.ropeTheta == 1_000_000, t.rmsNormEps == 1e-6,
              quantization == nil || (quantization?.groupSize == 64 && quantization?.bits == 8 && quantization?.mode == "affine") else {
            throw LocalASRError.invalidInput("Unsupported Qwen3-ASR configuration. Prepare the model again.")
        }
    }
}

struct QwenOutput {
    let text: String
    let tokens: [Int]
}

final class Qwen3ASRModel: Module {
    @ModuleInfo(key: "audio_tower") var audioTower: Qwen3ASRAudioEncoder
    @ModuleInfo(key: "model") var textModel: Qwen3ASRTextModel
    let tokenizer: QwenTokenizer

    init(config: QwenModelConfig, tokenizer: QwenTokenizer) {
        self._audioTower.wrappedValue = Qwen3ASRAudioEncoder(config.thinker.audioConfig)
        self._textModel.wrappedValue = Qwen3ASRTextModel(config.thinker.textConfig)
        self.tokenizer = tokenizer
    }

    static func fromDirectory(_ directory: URL, check: () throws -> Void) throws -> Qwen3ASRModel {
        let config = try JSONDecoder().decode(QwenModelConfig.self, from: Data(contentsOf: directory.appendingPathComponent("config.json")))
        try config.validate()
        try check()
        let tokenizer = try QwenTokenizer(directory: directory)
        let model = Qwen3ASRModel(config: config, tokenizer: tokenizer)
        let weights = try MLX.loadArrays(url: directory.appendingPathComponent("model.safetensors"))
        if let q = config.quantization {
            quantize(model: model) { path, _ in
                weights[path + ".scales"] == nil ? nil : (q.groupSize, q.bits, .affine)
            }
        }
        try check()
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: .all)
        eval(model)
        try check()
        return model
    }

    func generate(audio: [Float], context: [Int], maxTokens: Int = 512,
                  check: () throws -> Void) throws -> QwenOutput {
        try check()
        let mel = QwenAudio.features(audio).asType(audioTower.conv2d1.weight.dtype)
        eval(mel)
        var windows: [MLXArray] = []
        for offset in stride(from: 0, to: mel.dim(0), by: 800) {
            try check()
            let window = try audioTower.encodeSingleWindow(mel[offset..<min(offset + 800, mel.dim(0))], check: check)
            eval(window); windows.append(window)
        }
        let features = concatenated(windows, axis: 0)
        let prompt = QwenTokenizer.prompt(audioTokens: features.dim(0), contextTokens: context)
        let ids = MLXArray(prompt.ids.map(Int32.init)).expandedDimensions(axis: 0)
        let embeddings = textModel.embedTokens(ids)
        let end = prompt.audioStart + features.dim(0)
        let inputs = concatenated([embeddings[0..., 0..<prompt.audioStart],
                                   features.asType(embeddings.dtype).expandedDimensions(axis: 0),
                                   embeddings[0..., end...]], axis: 1)
        let cache = (0..<textModel.config.numHiddenLayers).map { _ in QwenKVCache() }
        var hidden: MLXArray?
        // Bound prefill activations and avoid projecting every prompt token to
        // the 152k-word vocabulary. Only the last hidden state predicts text.
        for offset in stride(from: 0, to: prompt.ids.count, by: 256) {
            try check()
            hidden = textModel(inputsEmbeds: inputs[0..., offset..<min(offset + 256, prompt.ids.count)], cache: cache)
            eval(hidden!); cache.forEach { $0.evaluate() }
        }
        var logits = textModel.embedTokens.asLinear(hidden![0..., -1, 0...]).asType(.float32)
        var generated: [Int] = []
        for _ in 0..<maxTokens {
            try check()
            // Penalize generated text only; words in the context stay available.
            if !generated.isEmpty {
                let recent = MLXArray(Set(generated.suffix(100)).sorted().map(Int32.init))
                let values = logits[0..., recent]
                logits[0..., recent] = MLX.where(values .> 0, values / Float(1.2), values * Float(1.2))
            }
            let next = logits.argMax(axis: -1)
            eval(next)
            try check()
            let token = next.item(Int.self)
            if QwenTokenizer.eosIDs.contains(token) {
                return QwenOutput(text: try tokenizer.transcript(generated), tokens: generated)
            }
            generated.append(token)
            let h = textModel(inputIds: MLXArray([Int32(token)]).reshaped(1, 1), cache: cache)
            logits = textModel.embedTokens.asLinear(h[0..., -1, 0...]).asType(.float32)
            eval(logits); cache.forEach { $0.evaluate() }
        }
        throw LocalASRError.invalidInput("Recognition reached its output limit. Please dictate a shorter phrase.")
    }
}
