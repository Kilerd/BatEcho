import Foundation

/// Only overlapping audio may remove repeated text. Pauses and silent segments
/// reset this relationship, preserving intentional repetitions in dictation.
struct TranscriptAssembler {
    private(set) var text = ""
    private var previous = ""

    private struct Unit {
        let text: String
        let range: Range<String.Index>
        let word: Bool
    }

    mutating func append(_ transcript: String, overlapDuration: TimeInterval) {
        let next = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { previous = next }
        guard !next.isEmpty else { return }
        var remainder = next
        if overlapDuration > 0, !previous.isEmpty, !text.isEmpty {
            let limit = min(64, max(2, Int(ceil(overlapDuration * 16))))
            let left = Array(Self.units(previous).suffix(limit))
            let right = Array(Self.units(next).prefix(limit))
            let count = min(left.count, right.count)
            var matched = false
            if count > 0 {
                for width in stride(from: count, through: 1, by: -1) {
                    // A lone Chinese character is too ambiguous to delete.
                    guard width >= 2 || (right[0].word && right[0].text.count >= 3) else { continue }
                    if left.suffix(width).map(\.text) == right.prefix(width).map(\.text) {
                        remainder = String(next[right[width - 1].range.upperBound...])
                        matched = true
                        break
                    }
                }
            }
            // Restore an English word cut in the middle of a forced boundary.
            if !matched, let end = left.last, let start = right.first,
               end.word, start.word, min(end.text.count, start.text.count) >= 4 {
                if start.text.hasPrefix(end.text), let tail = Self.units(text).last {
                    text = String(text[..<tail.range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else if end.text.hasSuffix(start.text) {
                    remainder = String(next[start.range.upperBound...])
                }
            }
        }
        remainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else { return }
        if let last = text.last, let first = remainder.first,
           Self.needsSpace(last, first) { text += " " }
        text += remainder
    }

    private static func needsSpace(_ left: Character, _ right: Character) -> Bool {
        let leftWord = left.isASCII && (left.isLetter || left.isNumber)
        let rightWord = right.isASCII && (right.isLetter || right.isNumber)
        return (leftWord && (right.isLetter || right.isNumber))
            || (rightWord && (left.isLetter || left.isNumber || ".,!?;:".contains(left)))
    }

    private static func units(_ text: String) -> [Unit] {
        var result: [Unit] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let start = index
            let hanzi = character.unicodeScalars.contains(where: HotwordTokenizer.isHanzi)
            if character.isLetter || character.isNumber {
                index = text.index(after: index)
                if !hanzi {
                    while index < text.endIndex {
                        let next = text[index]
                        guard (next.isLetter || next.isNumber || next == "'"),
                              !next.unicodeScalars.contains(where: HotwordTokenizer.isHanzi) else { break }
                        index = text.index(after: index)
                    }
                }
                result.append(.init(text: String(text[start..<index]).lowercased(), range: start..<index, word: !hanzi))
            } else { index = text.index(after: index) }
        }
        return result
    }
}
