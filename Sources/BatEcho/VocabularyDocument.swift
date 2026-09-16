import Foundation
import Darwin

/// A draft of the existing vocabulary file. Preserve fields that the editor
/// does not expose (including metadata written by earlier versions/tools).
final class VocabularyDocument {
    struct Row {
        let id: UUID
        var entry: VocabularyEntry
        fileprivate var fields: [String: Any]
    }

    let url: URL
    private let seed: Data
    private var sourceData: Data?
    private var original: Data = Data()
    private(set) var rows: [Row] = []
    var hasChanges: Bool { (try? encoded()) != original }
    var needsSave: Bool { hasChanges || sourceData == nil }

    init(url: URL, seed: Data = Data("[]".utf8)) throws {
        self.url = url
        self.seed = seed
        try reload()
    }

    func reload() throws {
        let disk = try Self.read(url)
        let data = disk ?? seed
        let entries = try VocabularyEntry.decode(data)
        guard let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              objects.count == entries.count else {
            throw LocalASRError.invalidInput("The vocabulary file must contain a list of words.")
        }
        let loaded = zip(entries, objects).map { entry, fields in Row(id: UUID(), entry: entry, fields: fields) }
        // Decode completely before replacing the current draft.
        let canonical = try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])
        rows = loaded
        sourceData = disk
        original = canonical
    }

    @discardableResult
    func add() -> UUID {
        let row = Row(id: UUID(), entry: .init(text: "", pinyin: []),
                      fields: ["text": "", "pinyin": [String](), "contexts": [String]()])
        rows.append(row)
        return row.id
    }

    func update(_ id: UUID, entry: VocabularyEntry) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let previous = rows[index].entry
        // Do not add absent optional fields just by selecting/editing a word.
        if previous.text != entry.text { rows[index].fields["text"] = entry.text }
        if previous.pinyin != entry.pinyin { rows[index].fields["pinyin"] = entry.pinyin }
        if previous.contexts != entry.contexts { rows[index].fields["contexts"] = entry.contexts }
        rows[index].entry = entry
    }

    func remove(_ id: UUID) { rows.removeAll { $0.id == id } }

    func matching(_ query: String) -> [Row] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return rows }
        return rows.filter {
            [$0.entry.text, $0.entry.pinyin.joined(separator: " ")].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    func validate(encode: ((String) throws -> [Int])? = nil) throws {
        var seen = Set<String>()
        for row in rows {
            let entry = row.entry
            let word = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { throw LocalASRError.invalidInput("Enter a word or phrase for each entry.") }
            guard entry.text.unicodeScalars.count <= 128 else {
                throw LocalASRError.invalidInput("Keep each word or phrase within 128 characters.")
            }
            guard !entry.text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw LocalASRError.invalidInput("A word cannot contain line breaks or control characters.")
            }
            let key = word.precomposedStringWithCanonicalMapping.lowercased()
            guard seen.insert(key).inserted else {
                throw LocalASRError.invalidInput("“\(entry.text)” already appears in your vocabulary. Keep one copy.")
            }
            if !entry.pinyin.isEmpty {
                guard entry.text.unicodeScalars.allSatisfy(HotwordTokenizer.isHanzi),
                      entry.pinyin.count == entry.text.unicodeScalars.count,
                      entry.pinyin.allSatisfy({ $0.range(of: "^[a-z]{1,16}$", options: .regularExpression) != nil }) else {
                    throw LocalASRError.invalidInput("For “\(entry.text)”, use one pinyin syllable per Chinese character, without tones (use v for ü), or leave pinyin blank.")
                }
            }
            guard entry.contexts.allSatisfy({ !$0.isEmpty && $0.count <= 128 }) else {
                throw LocalASRError.invalidInput("Keep each correction context within 128 characters.")
            }
        }
        _ = try QwenHotwords.context(entries: rows.map(\.entry), encode: encode ?? { _ in [] })
        _ = try VocabularyEntry.decode(encoded())
    }

    func save(encode: ((String) throws -> [Int])? = nil) throws {
        try validate(encode: encode)
        let data = try JSONSerialization.data(withJSONObject: rows.map(\.fields), options: [.prettyPrinted, .sortedKeys])
        guard data.count <= 1024 * 1024 else { throw LocalASRError.invalidInput("Vocabulary must be smaller than 1 MB.") }
        try assertUnchanged()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let staged = directory.appendingPathComponent(".vocabulary-\(UUID().uuidString).tmp")
        let descriptor = open(staged.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw LocalASRError.invalidInput("Cannot create the vocabulary file. Check folder permissions.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: staged) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        // A second check also catches edits made while the new file was written.
        try assertUnchanged()
        guard rename(staged.path, url.path) == 0 else {
            throw LocalASRError.invalidInput("Cannot save the vocabulary. Your previous file is unchanged.")
        }
        sourceData = data
        original = try encoded()
    }

    private func assertUnchanged() throws {
        guard try Self.read(url) == sourceData else {
            throw LocalASRError.invalidInput("The vocabulary changed outside this window. Reload it before saving so those changes are kept.")
        }
    }

    private func encoded() throws -> Data {
        try JSONSerialization.data(withJSONObject: rows.map(\.fields), options: [.sortedKeys])
    }

    private static func read(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 1024 * 1024 else { throw LocalASRError.invalidInput("Vocabulary must be smaller than 1 MB.") }
        return try Data(contentsOf: url)
    }
}
