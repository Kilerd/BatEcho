import Foundation

struct LLMConfig {
    var baseURL: String
    var apiKey: String
    var model: String

    static func fromSettings() -> LLMConfig {
        let settings = Settings.shared
        return LLMConfig(
            baseURL: settings.llmBaseURL,
            apiKey: settings.llmAPIKey,
            model: settings.llmModel
        )
    }

    var isUsable: Bool {
        !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !model.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

enum LLMError: LocalizedError {
    case invalidURL
    case httpError(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid API base URL."
        case .httpError(let code, let body):
            return "HTTP \(code): \(body)"
        case .emptyResponse:
            return "The model returned an empty response."
        }
    }
}

/// Sends the raw transcript to an OpenAI-compatible chat endpoint for a very
/// conservative cleanup pass. Any failure falls back to the original text.
final class LLMRefiner {
    // The CJK examples below are functional prompt data: they teach the model
    // the exact homophone-restoration behavior we want.
    static let systemPrompt = """
    You are a strict post-processor for speech-to-text (ASR) output. The user \
    message is a raw ASR transcript, possibly mixing Chinese and English.

    Your ONLY job is to fix obvious ASR mistakes:
    - Chinese homophone errors that are clearly wrong in the given context.
    - English technical terms that were transcribed as phonetic Chinese, \
    e.g. "配森" -> "Python", "杰森" -> "JSON", "吉特哈布" -> "GitHub".
    - Casing or spacing of well-known technical terms, e.g. "java script" -> "JavaScript".

    Hard rules:
    1. NEVER rewrite, rephrase, polish, translate, expand, summarize, or reorder the content.
    2. NEVER add or remove content. Keep filler words, repetition, and colloquial phrasing exactly as spoken.
    3. Keep the original punctuation unless it is clearly an ASR artifact.
    4. If you are not confident that a fragment is an ASR error, leave it untouched.
    5. If the whole input already looks correct, return it EXACTLY as-is.
    6. Output ONLY the corrected transcript: no explanation, no quotes, no markdown.
    """

    var isConfigured: Bool { LLMConfig.fromSettings().isUsable }

    /// Returns the refined transcript, or the original text on any failure.
    func refine(_ text: String) async -> String {
        do {
            let refined = try await Self.chat(config: .fromSettings(), userText: text)
            return refined.isEmpty ? text : refined
        } catch {
            NSLog("LLM refinement failed: \(error.localizedDescription)")
            return text
        }
    }

    static func test(config: LLMConfig) async -> Result<String, Error> {
        do {
            let reply = try await chat(config: config, userText: "hello")
            return .success(reply)
        } catch {
            return .failure(error)
        }
    }

    private static func chat(config: LLMConfig, userText: String) async throws -> String {
        var base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") {
            base.removeLast()
        }
        guard let url = URL(string: base + "/chat/completions") else {
            throw LLMError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let body = ChatRequest(
            model: config.model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userText),
            ],
            temperature: 0
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let snippet = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw LLMError.httpError(http.statusCode, snippet)
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            throw LLMError.emptyResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let messages: [Message]
        let temperature: Double
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }

            let message: Message
        }

        let choices: [Choice]
    }
}
