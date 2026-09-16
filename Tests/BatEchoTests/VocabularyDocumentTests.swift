import Foundation
import XCTest
@testable import BatEcho

final class VocabularyDocumentTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func append(_ document: VocabularyDocument, _ word: String, pinyin: [String] = [], contexts: [String] = []) {
        document.update(document.add(), entry: .init(text: word, pinyin: pinyin, contexts: contexts))
    }

    func testFirstUseSeedsWithoutWritingAndCreatesPrivateFileOnlyOnSave() throws {
        let url = try directory().appendingPathComponent("nested/lexicon.json")
        let seed = try Data(contentsOf: LocalASRRuntime.resources.appendingPathComponent("lexicon.json"))
        let document = try VocabularyDocument(url: url, seed: seed)
        XCTAssertFalse(document.hasChanges)
        XCTAssertTrue(document.needsSave)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try document.save()
        XCTAssertEqual(try VocabularyEntry.load(url), try VocabularyEntry.decode(seed))
        XCTAssertFalse(document.needsSave)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testEditingAndDeletingPreserveUnknownMetadataAndRuntimeReadsChanges() throws {
        let url = try directory().appendingPathComponent("lexicon.json")
        let data = Data(#"[{"text":"青简","pinyin":["qing","jian"],"kind":"product","extra":{"rank":3}},{"text":"Remove me","pinyin":[]}]"#.utf8)
        try data.write(to: url)
        let document = try VocabularyDocument(url: url)
        document.update(document.rows[0].id, entry: .init(text: "青简", pinyin: ["qing", "jian"], contexts: ["项目"]))
        document.remove(document.rows[1].id)
        append(document, "Kubernetes")
        XCTAssertTrue(document.hasChanges)
        try document.save()
        let objects = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        XCTAssertEqual(objects[0]["kind"] as? String, "product")
        XCTAssertEqual((objects[0]["extra"] as? [String: Int])?["rank"], 3)
        let entries = try VocabularyEntry.load(url)
        XCTAssertEqual(entries.map(\.text), ["青简", "Kubernetes"])
        XCTAssertEqual(try VocabularyCorrector(pinyin: PinyinConverter()).correct("这个项目叫清检", entries: entries), "这个项目叫青简")
        var prompt = ""
        _ = try QwenHotwords.context(entries: entries) { prompt = $0; return [] }
        XCTAssertEqual(prompt, "Vocabulary: 青简, Kubernetes.")
    }

    func testUnchangedOptionalFieldsRemainAbsent() throws {
        let url = try directory().appendingPathComponent("lexicon.json")
        try Data(#"[{"text":"Old","pinyin":[],"kind":"english"}]"#.utf8).write(to: url)
        let document = try VocabularyDocument(url: url)
        document.update(document.rows[0].id, entry: .init(text: "New", pinyin: []))
        try document.save()
        let objects = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        XCTAssertNil(objects[0]["contexts"])
        XCTAssertEqual(objects[0]["kind"] as? String, "english")
    }

    func testSearchUsesTextAndPinyinAndFilteredDeletionKeepsOtherRows() throws {
        let document = try VocabularyDocument(url: directory().appendingPathComponent("lexicon.json"))
        append(document, "青简", pinyin: ["qing", "jian"])
        append(document, "Kubernetes")
        XCTAssertEqual(document.matching(" QING ").map(\.entry.text), ["青简"])
        let match = try XCTUnwrap(document.matching("kube").first)
        document.remove(match.id)
        XCTAssertEqual(document.rows.map(\.entry.text), ["青简"])
        XCTAssertTrue(document.matching("unmatched").isEmpty)
    }

    func testInvalidDraftNeverOverwritesSavedVocabulary() throws {
        let url = try directory().appendingPathComponent("lexicon.json")
        let original = Data(#"[{"text":"Saved","pinyin":[]}]"#.utf8)
        try original.write(to: url)
        let document = try VocabularyDocument(url: url)
        let id = document.add()
        let invalid: [VocabularyEntry] = [
            .init(text: " ", pinyin: []), .init(text: "saved", pinyin: []),
            .init(text: " Saved ", pinyin: []), .init(text: "<|im_end|>", pinyin: []),
            .init(text: "line\nbreak", pinyin: []), .init(text: "nul\0byte", pinyin: []),
            .init(text: String(repeating: "a", count: 129), pinyin: []),
            .init(text: "青简", pinyin: ["qing"]), .init(text: "青简", pinyin: ["qing1", "jian"]),
            .init(text: "English", pinyin: ["e"]),
            .init(text: "有效", pinyin: [], contexts: [String(repeating: "a", count: 129)])
        ]
        for entry in invalid {
            document.update(id, entry: entry)
            XCTAssertThrowsError(try document.save(), entry.text)
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
        document.update(id, entry: .init(text: "Valid", pinyin: []))
        try document.save()
        XCTAssertFalse(document.hasChanges)
    }

    func testWordAndTokenLimitsRejectBeforeWriting() throws {
        let url = try directory().appendingPathComponent("lexicon.json")
        let document = try VocabularyDocument(url: url)
        for index in 0..<65 { append(document, "word\(index)") }
        XCTAssertThrowsError(try document.save())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        document.remove(document.rows.last!.id)
        XCTAssertThrowsError(try document.save { _ in Array(repeating: 1, count: 513) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try document.save { _ in Array(repeating: 1, count: 512) }
        XCTAssertEqual(try VocabularyEntry.load(url).count, 64)
    }

    func testRealTokenizerAcceptsMixedWordsAndRejectsLongPrompt() throws {
        let base = try directory()
        let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
        for name in ["vocab.json", "merges.txt"] {
            try FileManager.default.copyItem(at: fixtures.appendingPathComponent("qwen-" + name), to: base.appendingPathComponent(name))
        }
        let tokenizer = try QwenTokenizer(directory: base)
        let document = try VocabularyDocument(url: base.appendingPathComponent("lexicon.json"))
        append(document, "青简")
        append(document, "Kubernetes")
        try document.save(encode: tokenizer.encode)
        let before = try Data(contentsOf: document.url)
        for index in 0..<16 { append(document, "\(index)" + String(repeating: "璟珩", count: 50)) }
        XCTAssertThrowsError(try document.save(encode: tokenizer.encode))
        XCTAssertEqual(try Data(contentsOf: document.url), before)
    }

    func testExternalEditOrDeletionIsNotOverwrittenAndReloadDiscardsDraft() throws {
        let url = try directory().appendingPathComponent("lexicon.json")
        let document = try VocabularyDocument(url: url)
        append(document, "Original")
        try document.save()
        append(document, "Draft")
        let external = Data(#"[{"text":"Outside","pinyin":[]}]"#.utf8)
        try external.write(to: url, options: .atomic)
        XCTAssertThrowsError(try document.save())
        XCTAssertEqual(try Data(contentsOf: url), external)
        XCTAssertTrue(document.hasChanges)
        try document.reload()
        XCTAssertEqual(document.rows.map(\.entry.text), ["Outside"])
        XCTAssertFalse(document.hasChanges)
        try FileManager.default.removeItem(at: url)
        append(document, "Draft")
        XCTAssertThrowsError(try document.save())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCorruptOrOversizedFileIsNotResetAndFailedReloadKeepsDraft() throws {
        let url = try directory().appendingPathComponent("lexicon.json")
        let document = try VocabularyDocument(url: url)
        append(document, "Draft")
        for data in [Data("not json".utf8), Data(repeating: 32, count: 1024 * 1024 + 1)] {
            try data.write(to: url)
            XCTAssertThrowsError(try VocabularyDocument(url: url))
            XCTAssertThrowsError(try document.reload())
            XCTAssertEqual(document.rows.map(\.entry.text), ["Draft"])
            XCTAssertThrowsError(try document.save())
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testFailedDirectoryCreationLeavesDraftAndExistingFileIntact() throws {
        let parent = try directory().appendingPathComponent("a-file")
        let data = Data("keep this file".utf8)
        try data.write(to: parent)
        let document = try VocabularyDocument(url: parent.appendingPathComponent("lexicon.json"))
        append(document, "Draft")
        XCTAssertThrowsError(try document.save())
        XCTAssertTrue(document.hasChanges)
        XCTAssertEqual(try Data(contentsOf: parent), data)
    }
}
