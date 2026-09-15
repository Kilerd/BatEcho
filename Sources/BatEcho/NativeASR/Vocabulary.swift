import Foundation

struct VocabularyEntry: Decodable, Equatable {
    let text: String
    let pinyin: [String]
    let contexts: [String]

    init(text: String, pinyin: [String], contexts: [String] = []) {
        self.text = text
        self.pinyin = pinyin
        self.contexts = contexts
    }

    enum CodingKeys: String, CodingKey { case text, pinyin, contexts }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        pinyin = try c.decode([String].self, forKey: .pinyin)
        contexts = try c.decodeIfPresent([String].self, forKey: .contexts) ?? []
    }

    static func load(_ url: URL) throws -> [VocabularyEntry] {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 1024 * 1024 else { throw LocalASRError.invalidInput("Vocabulary must be smaller than 1 MB.") }
        let entries = try JSONDecoder().decode([VocabularyEntry].self, from: Data(contentsOf: url))
        guard entries.count <= 4096 else { throw LocalASRError.invalidInput("Vocabulary must contain at most 4096 entries.") }
        for entry in entries {
            guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  entry.text.unicodeScalars.count <= 128,
                  entry.pinyin.isEmpty || entry.pinyin.count == entry.text.unicodeScalars.count,
                  entry.pinyin.allSatisfy({ !$0.isEmpty && $0.count <= 16 }),
                  entry.contexts.allSatisfy({ !$0.isEmpty && $0.count <= 128 }) else {
                throw LocalASRError.invalidInput("Each vocabulary entry needs text, matching pinyin and nonempty contexts.")
            }
        }
        return entries
    }
}

/// Static pypinyin 0.55 data, evaluated entirely in Swift. Longest phrase match
/// preserves polyphonic readings (e.g. 重庆 / 银行) without ICU version drift.
final class PinyinConverter {
    private let characters: [String: String]
    private let phrases: [String: [String]]
    private let prefixes: Set<String>

    init(resources: URL = LocalASRRuntime.resources) throws {
        characters = try JSONDecoder().decode([String: String].self,
            from: Data(contentsOf: resources.appendingPathComponent("pinyin-characters.json")))
        phrases = try JSONDecoder().decode([String: [String]].self,
            from: Data(contentsOf: resources.appendingPathComponent("pinyin-phrases.json")))
        var prefixes = Set<String>()
        for phrase in phrases.keys {
            var prefix = ""
            for scalar in phrase.unicodeScalars {
                prefix.unicodeScalars.append(scalar)
                prefixes.insert(prefix)
            }
        }
        self.prefixes = prefixes
    }

    func syllables(_ text: String) -> [String] {
        let chars = Array(text.unicodeScalars).map(String.init)
        var output: [String] = []
        var index = 0
        while index < chars.count {
            var word = ""
            var match: [String]?
            var width = 0
            for end in index..<chars.count {
                word += chars[end]
                guard prefixes.contains(word) else { break }
                if let value = phrases[word] { match = value; width = end - index + 1 }
            }
            if let match { output += match; index += width }
            else { output.append(characters[chars[index]] ?? chars[index]); index += 1 }
        }
        return output
    }
}

final class VocabularyCorrector {
    private let pinyin: PinyinConverter
    init(pinyin: PinyinConverter) { self.pinyin = pinyin }

    private struct Edit {
        let start: Int
        let end: Int
        let after: String
    }

    /// Only exact homophones with an original-text context anchor may change.
    /// Ambiguous best candidates abstain. English/digits never enter this path.
    func correct(_ text: String, entries: [VocabularyEntry]) -> String {
        let characters = Array(text.unicodeScalars)
        var edits: [Edit] = []
        var position = 0
        while position < characters.count {
            guard HotwordTokenizer.isHanzi(characters[position]) else { position += 1; continue }
            let start = position
            while position < characters.count && HotwordTokenizer.isHanzi(characters[position]) { position += 1 }
            let segment = String(String.UnicodeScalarView(characters[start..<position]))
            let sounds = pinyin.syllables(segment)
            guard sounds.count == position - start else { continue }
            for entry in entries where entry.pinyin.count >= 2 && entry.contexts.contains(where: { text.contains($0) }) {
                let width = entry.pinyin.count
                guard width <= sounds.count else { continue }
                for offset in 0...(sounds.count - width) where Array(sounds[offset..<(offset + width)]) == entry.pinyin {
                    let from = start + offset
                    let before = String(String.UnicodeScalarView(characters[from..<(from + width)]))
                    if before != entry.text { edits.append(.init(start: from, end: from + width, after: entry.text)) }
                }
            }
        }
        edits.sort { ($0.start, -($0.end - $0.start), $0.after) < ($1.start, -($1.end - $1.start), $1.after) }
        var selections: [[Edit]] = [[]]
        for edit in edits {
            let additions = selections.filter { chosen in
                chosen.allSatisfy { edit.end <= $0.start || edit.start >= $0.end }
            }.map { $0 + [edit] }
            let combined = Array(selections.dropFirst()) + additions
            // Conservatively abstain if candidate enumeration would exceed its
            // bound, so truncating a tie can never create a false unique winner.
            guard combined.count < 16 else { return text }
            selections = [[]] + combined
        }
        var candidates: [String: Int] = [:]
        for selected in selections where !selected.isEmpty {
            var chars = characters
            for edit in selected.sorted(by: { $0.start > $1.start }) {
                chars.replaceSubrange(edit.start..<edit.end, with: edit.after.unicodeScalars)
            }
            let result = String(String.UnicodeScalarView(chars))
            candidates[result] = max(candidates[result] ?? 0, selected.count)
        }
        guard let most = candidates.values.max() else { return text }
        let winners = candidates.filter { $0.value == most }
        return winners.count == 1 ? winners.first!.key : text
    }
}
