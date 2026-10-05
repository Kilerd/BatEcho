import Foundation
import MLX

struct SpeechGateResult: Codable, Sendable {
    let hasSpeech: Bool
    let maxProbability: Float
    let longestSpeechMS: Int
    enum CodingKeys: String, CodingKey {
        case hasSpeech = "has_speech"
        case maxProbability = "max_probability"
        case longestSpeechMS = "longest_speech_ms"
    }
}

final class NativeASRPipeline: ASRPipeline {
    private let runtime: LocalASRRuntime
    private var model: Qwen3ASRModel?
    private var vad: SileroVAD?
    private var corrector: VocabularyCorrector?
    private var cachedWords: [String]?
    private var contextTokens: [Int] = []
    private var modelLoadCount = 0

    init(runtime: LocalASRRuntime) { self.runtime = runtime }

    deinit {
        if model != nil || vad != nil {
            model = nil
            vad = nil
            Memory.clearCache()
        }
    }

    private func loadModel(check: () throws -> Void) throws -> Qwen3ASRModel {
        try check()
        if let model { return model }
        Memory.cacheLimit = 128 * 1024 * 1024
        let directory = runtime.models.appendingPathComponent(LocalASRRuntime.modelDirectoryName)
        let loaded = try Qwen3ASRModel.fromDirectory(directory, check: check)
        model = loaded
        modelLoadCount += 1
        try check()
        return loaded
    }

    private func loadVAD() throws -> SileroVAD {
        if let vad { return vad }
        let loaded = try SileroVAD.fromModelDirectory(runtime.models.appendingPathComponent("silero-v6"))
        vad = loaded
        return loaded
    }

    func warmUp(check: () throws -> Void) throws -> LocalASRResponse {
        guard runtime.isPrepared else { throw LocalASRError.notPrepared }
        try check()
        _ = try loadVAD()
        _ = try loadModel(check: check)
        return LocalASRResponse(ready: true, modelLoadCount: modelLoadCount)
    }

    func correct(text: String, check: () throws -> Void) throws -> String {
        try check()
        guard runtime.isPrepared else { throw LocalASRError.notPrepared }
        let entries = try VocabularyEntry.load(runtime.vocabulary)
        if corrector == nil { corrector = try VocabularyCorrector(pinyin: PinyinConverter()) }
        let result = corrector!.correct(text, entries: entries)
        try check()
        return result
    }

    private func speechGate(_ audio: [Float], check: () throws -> Void) throws -> SpeechGateResult {
        try Stream.withNewDefaultStream(device: .cpu) {
            try speechGateOnCurrentStream(audio, check: check)
        }
    }

    private func speechGateOnCurrentStream(_ audio: [Float], check: () throws -> Void) throws -> SpeechGateResult {
        let detector = try loadVAD()
        var state = try detector.initialState()
        var run = 0, longest = 0
        var peak: Float = 0
        for offset in stride(from: 0, to: audio.count, by: 512) {
            try check()
            var chunk = Array(audio[offset..<min(offset + 512, audio.count)])
            chunk += Array(repeating: 0, count: 512 - chunk.count)
            let (probability, next) = try detector.feed(chunk: MLXArray(chunk), state: state)
            eval(probability, next.context, next.lstmState!)
            try check()
            let value = probability.item(Float.self)
            guard value.isFinite else { throw LocalASRError.invalidInput("Speech detection failed.") }
            state = next
            peak = max(peak, value)
            run = value >= 0.5 ? run + 1 : 0
            longest = max(longest, run)
        }
        return .init(hasSpeech: longest >= 5, maxProbability: peak, longestSpeechMS: longest * 32)
    }

    func transcribe(audio url: URL, options: ASROptions, check: () throws -> Void) throws -> LocalASRResponse {
        guard runtime.isPrepared else { throw LocalASRError.notPrepared }
        try check()
        let started = ProcessInfo.processInfo.systemUptime
        let audio = try NativeAudio.read(url)
        let gate = try speechGate(audio, check: check)
        var result = LocalASRResponse(text: "", rawText: "", vad: gate)
        if gate.hasSpeech {
            let entries = try VocabularyEntry.load(runtime.vocabulary)
            let model = try loadModel(check: check)
            var activeContext: [Int] = []
            if options.hotwords {
                let words = entries.map(\.text)
                if cachedWords != words {
                    contextTokens = try QwenHotwords.context(entries: entries, encode: model.tokenizer.encode)
                    cachedWords = words
                }
                activeContext = contextTokens
            }
            let output = try model.generate(audio: audio, context: activeContext, check: check)
            result.rawText = output.text
            result.text = output.text
            result.tokens = output.tokens
            if options.correction {
                if corrector == nil { corrector = try VocabularyCorrector(pinyin: PinyinConverter()) }
                result.text = corrector!.correct(output.text, entries: entries)
            }
        }
        try check()
        result.modelLoadCount = modelLoadCount
        result.elapsedSeconds = ProcessInfo.processInfo.systemUptime - started
        return result
    }
}
