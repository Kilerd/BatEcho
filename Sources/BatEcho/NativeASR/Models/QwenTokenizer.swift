import Foundation

/// Qwen2 byte-level BPE. Ordinary text never expands chat/audio control tokens;
/// the recognition prompt inserts those IDs explicitly.
final class QwenTokenizer {
    private let vocabulary: [String: Int]
    private let decoded: [Int: [UInt8]]
    private let ranks: [String: Int]
    private let byteEncoder: [String]
    private let pattern: NSRegularExpression
    static let audioID = 151676
    static let textID = 151704
    static let eosIDs: Set<Int> = [151643, 151645]

    init(directory: URL) throws {
        vocabulary = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: directory.appendingPathComponent("vocab.json")))
        guard vocabulary.count == 151643, Set(vocabulary.values).count == vocabulary.count,
              vocabulary.values.allSatisfy({ (0..<151643).contains($0) }) else {
            throw LocalASRError.invalidInput("Invalid Qwen vocabulary. Prepare the model again.")
        }
        var bytes = Array(33...126) + Array(161...172) + Array(174...255)
        var codepoints = bytes
        var extra = 0
        for byte in 0...255 where !bytes.contains(byte) {
            bytes.append(byte); codepoints.append(256 + extra); extra += 1
        }
        var encoder = Array(repeating: "", count: 256)
        var decoder: [Unicode.Scalar: UInt8] = [:]
        for (byte, codepoint) in zip(bytes, codepoints) {
            let scalar = Unicode.Scalar(codepoint)!
            encoder[byte] = String(scalar); decoder[scalar] = UInt8(byte)
        }
        byteEncoder = encoder
        var decoded: [Int: [UInt8]] = [:]
        for (piece, id) in vocabulary {
            let values = piece.unicodeScalars.compactMap { decoder[$0] }
            guard values.count == piece.unicodeScalars.count else {
                throw LocalASRError.invalidInput("Invalid byte mapping in Qwen vocabulary.")
            }
            decoded[id] = values
        }
        self.decoded = decoded
        let merges = try String(contentsOf: directory.appendingPathComponent("merges.txt"), encoding: .utf8)
            .split(separator: "\n").filter { !$0.hasPrefix("#version:") }
        var ranks: [String: Int] = [:]
        for (rank, pair) in merges.enumerated() {
            guard pair.split(separator: " ").count == 2, ranks[String(pair)] == nil else {
                throw LocalASRError.invalidInput("Invalid Qwen BPE merges.")
            }
            ranks[String(pair)] = rank
        }
        self.ranks = ranks
        pattern = try NSRegularExpression(pattern: #"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+"#)
    }

    func encode(_ text: String) throws -> [Int] {
        let text = text.precomposedStringWithCanonicalMapping
        let string = text as NSString
        var output: [Int] = []
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            var pieces = string.substring(with: match.range).utf8.map { byteEncoder[Int($0)] }
            while pieces.count > 1 {
                var best: (rank: Int, index: Int)?
                for index in 0..<(pieces.count - 1) {
                    if let rank = ranks[pieces[index] + " " + pieces[index + 1]], rank < (best?.rank ?? Int.max) {
                        best = (rank, index)
                    }
                }
                guard let best else { break }
                pieces[best.index] += pieces[best.index + 1]
                pieces.remove(at: best.index + 1)
            }
            for piece in pieces {
                guard let id = vocabulary[piece] else { throw LocalASRError.invalidInput("Qwen cannot encode this vocabulary entry.") }
                output.append(id)
            }
        }
        return output
    }

    func decode(_ ids: [Int]) -> String {
        String(decoding: ids.flatMap { decoded[$0] ?? [] }, as: UTF8.self)
    }

    static func prompt(audioTokens: Int, contextTokens: [Int]) -> (ids: [Int], audioStart: Int) {
        let prefix = [151644, 8948, 198] + contextTokens + [151645, 198, 151644, 872, 198, 151669]
        return (prefix + Array(repeating: audioID, count: audioTokens) + [151670, 151645, 198, 151644, 77091, 198], prefix.count)
    }

    func transcript(_ generated: [Int]) throws -> String {
        if generated.isEmpty { return "" }
        guard let marker = generated.firstIndex(of: Self.textID) else {
            // Qwen may emit only a no-speech language header.
            if decode(generated).trimmingCharacters(in: .whitespacesAndNewlines) == "language None" { return "" }
            throw LocalASRError.invalidInput("Qwen returned an incomplete transcript. Please try again.")
        }
        return decode(Array(generated.dropFirst(marker + 1))).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum QwenHotwords {
    static func context(entries: [VocabularyEntry], encode: (String) throws -> [Int]) throws -> [Int] {
        var seen = Set<String>()
        let words = entries.compactMap { entry -> String? in
            let word = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, seen.insert(word.lowercased()).inserted else { return nil }
            return word
        }
        guard words.count <= 64 else { throw LocalASRError.invalidInput("Use up to 64 relevant vocabulary words for recognition.") }
        guard !words.isEmpty else { return [] }
        guard words.allSatisfy({ !$0.contains("\n") && !$0.contains("\r") && !$0.contains("<|") && !$0.contains("<asr_text>") }) else {
            throw LocalASRError.invalidInput("Vocabulary words cannot contain line breaks or model control markers.")
        }
        let tokens = try encode("Vocabulary: " + words.joined(separator: ", ") + ".")
        guard tokens.count <= 512 else { throw LocalASRError.invalidInput("The vocabulary prompt is too long. Use fewer or shorter words.") }
        return tokens
    }
}
