import Foundation

struct Language {
    let name: String
    let localeID: String
}

enum Languages {
    static let all: [Language] = [
        Language(name: "Simplified Chinese", localeID: "zh-CN"),
        Language(name: "English", localeID: "en-US"),
        Language(name: "Traditional Chinese", localeID: "zh-TW"),
        Language(name: "Japanese", localeID: "ja-JP"),
        Language(name: "Korean", localeID: "ko-KR"),
    ]
}

final class Settings {
    static let shared = Settings()

    private enum Keys {
        static let language = "language"
        static let llmEnabled = "llm.enabled"
        static let llmBaseURL = "llm.baseURL"
        static let llmAPIKey = "llm.apiKey"
        static let llmModel = "llm.model"
    }

    private let defaults = UserDefaults.standard

    private init() {}

    var languageID: String {
        get { defaults.string(forKey: Keys.language) ?? "zh-CN" }
        set { defaults.set(newValue, forKey: Keys.language) }
    }

    var llmEnabled: Bool {
        get { defaults.bool(forKey: Keys.llmEnabled) }
        set { defaults.set(newValue, forKey: Keys.llmEnabled) }
    }

    var llmBaseURL: String {
        get { defaults.string(forKey: Keys.llmBaseURL) ?? "https://api.openai.com/v1" }
        set { defaults.set(newValue, forKey: Keys.llmBaseURL) }
    }

    var llmAPIKey: String {
        get { defaults.string(forKey: Keys.llmAPIKey) ?? "" }
        set { defaults.set(newValue, forKey: Keys.llmAPIKey) }
    }

    var llmModel: String {
        get { defaults.string(forKey: Keys.llmModel) ?? "gpt-4o-mini" }
        set { defaults.set(newValue, forKey: Keys.llmModel) }
    }
}
