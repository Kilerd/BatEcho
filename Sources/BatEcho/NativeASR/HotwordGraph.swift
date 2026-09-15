import Foundation

struct HotwordPhrase: Equatable {
    let text: String
    let tokens: [Int]
    let englishBoundary: Bool
}

enum HotwordTokenizer {
    static func compile(_ words: [String], vocabulary: [String],
                        sentencePiece: SentencePieceTokenizer) throws -> [HotwordPhrase] {
        guard words.count <= 64 else { throw LocalASRError.invalidInput("Select at most 64 hotwords.") }
        let ids = Dictionary(uniqueKeysWithValues: vocabulary.enumerated().map { ($1, $0) })
        var result: [HotwordPhrase] = []
        var seen = Set<[Int]>()
        for word in words {
            guard word.count <= 128 else { throw LocalASRError.invalidInput("A hotword is too long.") }
            let normalized = word.precomposedStringWithCompatibilityMapping.uppercased()
                .replacingOccurrences(of: "[，。？！,.?!]", with: " ", options: .regularExpression)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            var pieces: [String] = []
            var english = ""
            func flush() {
                let part = english.trimmingCharacters(in: .whitespacesAndNewlines)
                if !part.isEmpty {
                    pieces += sentencePiece.encodeWithByteFallback(part).compactMap { sentencePiece.token(for: $0) }
                }
                english = ""
            }
            for scalar in normalized.unicodeScalars {
                if isHanzi(scalar) {
                    flush()
                    pieces.append(String(scalar))
                } else {
                    english.unicodeScalars.append(scalar)
                }
            }
            flush()
            let tokens = pieces.map { ids[$0] ?? 1 }
            guard !tokens.isEmpty, tokens.allSatisfy({ $0 >= 5 }) else {
                throw LocalASRError.invalidInput("FireRed cannot encode this hotword: \(word)")
            }
            if seen.insert(tokens).inserted {
                let last = normalized.unicodeScalars.last
                let boundary = last.map { (65...90).contains($0.value) || (48...57).contains($0.value) } ?? false
                result.append(.init(text: word, tokens: tokens, englishBoundary: boundary))
            }
        }
        guard result.reduce(0, { $0 + $1.tokens.count }) <= 512 else {
            throw LocalASRError.invalidInput("Select fewer hotwords (at most 512 model tokens).")
        }
        return result
    }

    static func isHanzi(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
    }
}

/// Aho-Corasick context bias. Each phrase earns its score once per utterance.
/// Unfinished prefixes are refunded; English completions require a word boundary.
final class HotwordGraph {
    private struct Node {
        var children: [Int: Int] = [:]
        var failure = 0
        var prefixes: [Int: Float] = [:]
        var immediate: UInt64 = 0
        var deferred: UInt64 = 0
    }
    struct State: Hashable {
        var node = 0
        var seen: UInt64 = 0
    }
    private var nodes = [Node()]
    private var alphabet = Set<Int>()
    private let boundaries: [Bool]
    private let score: Float
    private var cache: [State: [Float]] = [:]
    private var cacheOrder: [State] = []

    init(phrases: [HotwordPhrase], vocabulary: [String], eosID: Int, score: Float) throws {
        guard score.isFinite, (0...8).contains(score), phrases.count <= 64 else {
            throw LocalASRError.invalidInput("Hotword strength must be between 0 and 8.")
        }
        self.score = score
        boundaries = vocabulary.enumerated().map { index, piece in
            let continuation = !piece.isEmpty && piece.unicodeScalars.allSatisfy {
                (65...90).contains($0.value) || (48...57).contains($0.value) || $0 == "_" || $0 == "'"
            }
            return index == eosID || (index >= 5 && (piece.hasPrefix("▁") || !continuation))
        }
        var unique = Set<[Int]>()
        for phrase in phrases where !phrase.tokens.isEmpty {
            guard phrase.tokens.allSatisfy({ vocabulary.indices.contains($0) && $0 >= 5 }) else {
                throw LocalASRError.invalidInput("Hotword contains an invalid model token.")
            }
            let phraseID = unique.count
            guard unique.insert(phrase.tokens).inserted else { continue }
            var node = 0
            for (offset, token) in phrase.tokens.enumerated() {
                alphabet.insert(token)
                if nodes[node].children[token] == nil {
                    nodes[node].children[token] = nodes.count
                    nodes.append(Node())
                }
                node = nodes[node].children[token]!
                nodes[node].prefixes[phraseID] = score * Float(offset + 1) / Float(phrase.tokens.count)
            }
            if phrase.englishBoundary { nodes[node].deferred |= UInt64(1) << phraseID }
            else { nodes[node].immediate |= UInt64(1) << phraseID }
        }
        var queue = Array(nodes[0].children.values)
        var cursor = 0
        while cursor < queue.count {
            let node = queue[cursor]
            cursor += 1
            for (token, child) in nodes[node].children {
                var failure = nodes[node].failure
                while failure != 0 && nodes[failure].children[token] == nil { failure = nodes[failure].failure }
                nodes[child].failure = nodes[failure].children[token] ?? 0
                let suffix = nodes[nodes[child].failure]
                nodes[child].immediate |= suffix.immediate
                nodes[child].deferred |= suffix.deferred
                for (id, potential) in suffix.prefixes {
                    nodes[child].prefixes[id] = max(nodes[child].prefixes[id] ?? 0, potential)
                }
                queue.append(child)
            }
        }
    }

    private func potential(_ state: State) -> Float {
        nodes[state.node].prefixes.filter { state.seen & (UInt64(1) << $0.key) == 0 }.values.max() ?? 0
    }

    func step(_ state: State, token: Int) -> (State, Float) {
        var node = state.node
        while node != 0 && nodes[node].children[token] == nil { node = nodes[node].failure }
        let following = nodes[node].children[token] ?? 0
        var completed = nodes[following].immediate
        if boundaries[token] { completed |= nodes[state.node].deferred }
        let newlyCompleted = completed & ~state.seen
        let next = State(node: following, seen: state.seen | newlyCompleted)
        return (next, potential(next) - potential(state) + Float(newlyCompleted.nonzeroBitCount) * score)
    }

    func finalize(_ state: State) -> Float { -potential(state) }

    func rewards(_ state: State) -> [Float] {
        if let value = cache[state] { return value }
        let pending = Float((nodes[state.node].deferred & ~state.seen).nonzeroBitCount) * score
        let base = -potential(state)
        var values = boundaries.map { base + ($0 ? pending : 0) }
        for token in alphabet { values[token] = step(state, token: token).1 }
        if cacheOrder.count >= 256 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        cacheOrder.append(state)
        cache[state] = values
        return values
    }
}
