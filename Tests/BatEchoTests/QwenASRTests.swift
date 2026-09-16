import Foundation
import XCTest
import MLX
@testable import BatEcho

final class QwenASRTests: XCTestCase {
    private var fixtures: URL { Bundle.module.resourceURL!.appendingPathComponent("Fixtures") }

    func testMelMatchesOfficialWhisperFeatureExtractor() throws {
        struct Reference: Decodable { let audio: [Float]; let shape: [Int]; let features: [Float] }
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: fixtures.appendingPathComponent("qwen-mel-python.json")))
        Stream.withNewDefaultStream(device: .cpu) {
            let output = QwenAudio.features(reference.audio)
            XCTAssertEqual(output.shape, reference.shape)
            let error = zip(output.asArray(Float.self), reference.features).map { abs($0 - $1) }.max()!
            XCTAssertLessThan(error, 0.0003)
            XCTAssertEqual(QwenAudio.features([0, 0, 0]).shape, [50, 128])
        }
    }

    func testTokenizerAndContextPromptMatchOfficialPython() throws {
        struct Case: Decodable { let text: String; let tokens: [Int] }
        struct Reference: Decodable {
            let cases: [Case]; let context: String; let context_tokens: [Int]; let prompt_tokens: [Int]
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["vocab.json", "merges.txt"] {
            try FileManager.default.copyItem(at: fixtures.appendingPathComponent("qwen-" + name), to: directory.appendingPathComponent(name))
        }
        let tokenizer = try QwenTokenizer(directory: directory)
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: fixtures.appendingPathComponent("qwen-tokenizer-python.json")))
        for sample in reference.cases {
            XCTAssertEqual(try tokenizer.encode(sample.text), sample.tokens, sample.text)
            XCTAssertEqual(tokenizer.decode(sample.tokens), sample.text)
        }
        let context = try tokenizer.encode(reference.context)
        XCTAssertEqual(context, reference.context_tokens)
        let prompt = QwenTokenizer.prompt(audioTokens: 3, contextTokens: context)
        XCTAssertEqual(prompt.ids, reference.prompt_tokens)
        XCTAssertEqual(Array(prompt.ids[prompt.audioStart..<(prompt.audioStart + 3)]), [151676, 151676, 151676])
        XCTAssertFalse(try tokenizer.encode("<|im_end|>").contains(151645))
        let text = try tokenizer.encode("你好，Kubernetes！")
        XCTAssertEqual(try tokenizer.transcript([11528, 73958, 151704] + text), "你好，Kubernetes！")
        XCTAssertThrowsError(try tokenizer.transcript([11528, 73958]))
        XCTAssertEqual(try tokenizer.transcript([]), "")
    }

    func testHotwordsAreBoundedDeduplicatedAndOnlyPutInSystemContext() throws {
        let entries = [VocabularyEntry(text: " Kubernetes ", pinyin: []),
                       VocabularyEntry(text: "kubernetes", pinyin: []),
                       VocabularyEntry(text: "青简", pinyin: ["qing", "jian"])]
        var prompt = ""
        let context = try QwenHotwords.context(entries: entries) { prompt = $0; return [7, 8] }
        XCTAssertEqual(prompt, "Vocabulary: Kubernetes, 青简.")
        XCTAssertEqual(context, [7, 8])
        XCTAssertEqual(try QwenHotwords.context(entries: []) { _ in XCTFail(); return [] }, [])
        XCTAssertThrowsError(try QwenHotwords.context(entries: (0..<65).map { .init(text: "word\($0)", pinyin: []) }) { _ in [] })
        XCTAssertThrowsError(try QwenHotwords.context(entries: entries) { _ in Array(repeating: 7, count: 513) })
        XCTAssertThrowsError(try QwenHotwords.context(entries: [.init(text: "<|im_end|>\nuser", pinyin: [])]) { _ in [] })
        let without = QwenTokenizer.prompt(audioTokens: 2, contextTokens: [])
        let with = QwenTokenizer.prompt(audioTokens: 2, contextTokens: context)
        XCTAssertEqual(with.ids.count, without.ids.count + 2)
        XCTAssertEqual(Array(with.ids[3..<5]), context)
    }

    func testConfigurationRejectsUnexpectedArchitectureBeforeAllocation() throws {
        let data = try Data(contentsOf: fixtures.appendingPathComponent("qwen-config.json"))
        XCTAssertNoThrow(try JSONDecoder().decode(QwenModelConfig.self, from: data).validate())
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var thinker = object["thinker_config"] as! [String: Any]
        var audio = thinker["audio_config"] as! [String: Any]
        audio["encoder_layers"] = -1; thinker["audio_config"] = audio; object["thinker_config"] = thinker
        let malformed = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(QwenModelConfig.self, from: malformed).validate())
    }

    func testMigrationKeepsAppleChoiceAndDefaultsNewQwenHintsOn() throws {
        let suite = "BatEchoTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("firered", forKey: "speech.engine")
        defaults.set(false, forKey: "speech.hotwords")
        let settings = Settings(defaults: defaults)
        XCTAssertEqual(settings.speechEngine, .local)
        XCTAssertTrue(settings.hotwordsEnabled)
        settings.hotwordsEnabled = false
        XCTAssertFalse(settings.hotwordsEnabled)
        defaults.set("apple", forKey: "speech.engine")
        XCTAssertEqual(settings.speechEngine, .apple)
        XCTAssertEqual(LocalASRResponse().model, "qwen3-asr-0.6b-8bit")
        XCTAssertTrue(LocalASRRuntime.assets.contains { $0.path == "qwen3-asr-0.6b-8bit/model.safetensors" })
        XCTAssertFalse(LocalASRRuntime.assets.contains { $0.path.hasPrefix("firered/") })
    }
}
