import AVFoundation
import XCTest
import MLX
@testable import voicer

final class NativeASRTests: XCTestCase {
    private var fixtures: URL { Bundle.module.resourceURL!.appendingPathComponent("Fixtures") }

    func testMalformedModelConfigurationIsRejectedBeforeAllocation() throws {
        XCTAssertNoThrow(try FireRedASR2Config().validateForVoicer())
        let invalid = FireRedASR2Config(encoder: .init(nLayers: -1))
        XCTAssertThrowsError(try invalid.validateForVoicer())
    }

    func testFbankMatchesFrozenPythonRecipe() throws {
        struct Reference: Decodable { let audio: [Float]; let shape: [Int]; let features: [Float] }
        let reference = try JSONDecoder().decode(Reference.self,
            from: Data(contentsOf: fixtures.appendingPathComponent("fbank-python.json")))
        // Hosted CI can compile Metal without exposing a GPU. Real GPU model
        // parity is separately checked on Apple Silicon with check_swift_parity.
        Stream.withNewDefaultStream(device: .cpu) {
            let output = FireRedASR2Audio.extractFbank(MLXArray(reference.audio))
            XCTAssertEqual(output.shape, reference.shape)
            let difference = zip(output.asArray(Float.self), reference.features).map { abs($0 - $1) }.max()!
            XCTAssertLessThan(difference, 0.0001, "Feature extraction drifted from the Python reference")
        }
    }

    func testPinyinPolyphonesAndConservativeCorrection() throws {
        let converter = try PinyinConverter()
        XCTAssertEqual(converter.syllables("重庆银行行长"), ["chong", "qing", "yin", "hang", "hang", "zhang"])
        let corrector = VocabularyCorrector(pinyin: converter)
        let entries = try VocabularyEntry.load(LocalASRRuntime.resources.appendingPathComponent("lexicon.json"))
        XCTAssertEqual(corrector.correct("请发给同事齐彦。", entries: entries), "请发给同事祁砚。")
        XCTAssertEqual(corrector.correct("请把婚礼请柬放在桌子上。", entries: entries), "请把婚礼请柬放在桌子上。")
        XCTAssertEqual(corrector.correct("请发给同事景恒", entries: entries), "请发给同事璟珩")
        let ambiguous = entries + [.init(text: "齐燕", pinyin: ["qi", "yan"], contexts: ["同事"])]
        XCTAssertEqual(corrector.correct("同事齐彦到了。", entries: ambiguous), "同事齐彦到了。")
        let english = "Cloudflare API v2: 2026-09-15, id=123."
        XCTAssertEqual(corrector.correct(english, entries: entries), english)
    }

    func testCorrectionMatchesPythonAcrossResearchTranscripts() throws {
        struct Reference: Decodable { let input: String; let expected: String }
        let rows = try JSONDecoder().decode([Reference].self,
            from: Data(contentsOf: fixtures.appendingPathComponent("correction-python.json")))
        let corrector = try VocabularyCorrector(pinyin: PinyinConverter())
        let entries = try VocabularyEntry.load(LocalASRRuntime.resources.appendingPathComponent("lexicon.json"))
        for row in rows { XCTAssertEqual(corrector.correct(row.input, entries: entries), row.expected, row.input) }
    }

    func testOverlappingCorrectionDoesNotDuplicateText() throws {
        let corrector = try VocabularyCorrector(pinyin: PinyinConverter())
        let entries = [VocabularyEntry(text: "青简", pinyin: ["qing", "jian"], contexts: ["项目"]),
                       VocabularyEntry(text: "青简输入法", pinyin: ["qing", "jian", "shu", "ru", "fa"], contexts: ["项目"])]
        XCTAssertEqual(corrector.correct("项目清简输入法", entries: entries), "项目青简输入法")
    }

    func testRealSentencePieceMatchesPythonForEnglishHotwords() throws {
        struct Reference: Decodable { let word: String; let pieces: [String]; let encodable: Bool }
        let reference = try JSONDecoder().decode([Reference].self,
            from: Data(contentsOf: fixtures.appendingPathComponent("sentencepiece-parity.json")))
        let sp = try SentencePieceTokenizer.from(sentencePieceModelURL: fixtures.appendingPathComponent("train_bpe1000.model"))
        let vocabulary = try FireRedASR2Tokenizer(modelDirectory: fixtures).vocabulary
        for sample in reference {
            if !sample.encodable {
                XCTAssertThrowsError(try HotwordTokenizer.compile([sample.word], vocabulary: vocabulary, sentencePiece: sp))
                continue
            }
            let phrases = try HotwordTokenizer.compile([sample.word], vocabulary: vocabulary, sentencePiece: sp)
            XCTAssertEqual(phrases[0].tokens.map { vocabulary[$0] }, sample.pieces, sample.word)
        }
        XCTAssertThrowsError(try HotwordTokenizer.compile(["🦄"], vocabulary: vocabulary, sentencePiece: sp))
        XCTAssertThrowsError(try HotwordTokenizer.compile(Array(repeating: "API", count: 65), vocabulary: vocabulary, sentencePiece: sp))
    }

    func testHotwordRefundWordBoundaryAndOncePerUtterance() throws {
        let vocabulary = ["<blank>", "<unk>", "<pad>", "<sos>", "<eos>", "青", "简", "▁API", "S", "▁IS", "人"]
        let graph = try HotwordGraph(phrases: [
            .init(text: "青简", tokens: [5, 6], englishBoundary: false),
            .init(text: "API", tokens: [7], englishBoundary: true)
        ], vocabulary: vocabulary, eosID: 4, score: 4)
        var state = HotwordGraph.State()
        var total: Float = 0
        (state, total) = graph.step(state, token: 5)
        XCTAssertEqual(total + graph.finalize(state), 0)
        let next = graph.step(state, token: 6)
        state = next.0; total += next.1
        XCTAssertEqual(total, 4)
        for token in [5, 6, 5, 6] {
            let next = graph.step(state, token: token); state = next.0; total += next.1
        }
        XCTAssertEqual(total + graph.finalize(state), 4)
        let api = graph.step(.init(), token: 7)
        XCTAssertEqual(api.1 + graph.finalize(api.0), 0)
        XCTAssertEqual(api.1 + graph.step(api.0, token: 8).1, 0, "API must not match APIS")
        XCTAssertEqual(api.1 + graph.step(api.0, token: 4).1, 4)
        XCTAssertEqual(api.1 + graph.step(api.0, token: 9).1, 4)
        for token in vocabulary.indices {
            XCTAssertEqual(graph.rewards(api.0)[token], graph.step(api.0, token: token).1)
        }
    }

    func testNativeStereoResamplingPreservesDurationAndMixesChannels() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let capture = try AudioCapture(format: format)
        defer { capture.discard() }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
        buffer.frameLength = 48000
        for index in 0..<48000 {
            let value = Float(sin(2 * Double.pi * 440 * Double(index) / 48000)) * 0.5
            buffer.floatChannelData![0][index] = value
            buffer.floatChannelData![1][index] = -value
        }
        try capture.append(buffer)
        capture.finish()
        let samples = try NativeAudio.read(capture.url)
        XCTAssertEqual(samples.count, 16000)
        XCTAssertLessThan(samples.map(abs).max() ?? 0, 1e-6)
    }
}
