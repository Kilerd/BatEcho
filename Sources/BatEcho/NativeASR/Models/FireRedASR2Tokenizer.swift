// SPDX-License-Identifier: MIT
// Adapted from Blaizzy/mlx-audio-swift at 3e978558404df4ad1bbb0a5634a03df2b0f9dfa5.
// Copyright (c) 2025 Prince Canuma. See ASRResources/ThirdPartyNotices.txt.

import Foundation

struct FireRedASR2Tokenizer: Sendable {
    let vocabulary: [String]

    init(vocabulary: [String]) {
        self.vocabulary = vocabulary
    }

    init(modelDirectory: URL) throws {
        let dictURL = modelDirectory.appendingPathComponent("dict.txt")
        let contents = try String(contentsOf: dictURL, encoding: .utf8)
        let tokens = contents.split(whereSeparator: \.isNewline).map { line -> String in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let token = parts.first else { return " " }
            return token == "<space>" ? " " : String(token)
        }
        self.vocabulary = tokens
    }

    func decode(tokenIds: [Int]) -> String {
        let pieces = tokenIds.compactMap { tokenID -> String? in
            guard vocabulary.indices.contains(tokenID) else { return nil }
            return vocabulary[tokenID]
        }

        var text = pieces.joined()
        text = text.replacingOccurrences(of: "\u{2581}", with: " ")
        text = text.replacingOccurrences(of: "<blank>", with: "")
        text = text.replacingOccurrences(of: "<sil>", with: "")
        return text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
