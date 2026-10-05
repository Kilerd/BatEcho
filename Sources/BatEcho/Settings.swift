import Foundation

enum SpeechEngine: String, CaseIterable {
    case local = "qwen3-asr"
    case apple = "apple"

    var title: String {
        switch self {
        case .local: return "Local Qwen3-ASR · Chinese / English"
        case .apple: return "Apple Speech Recognition"
        }
    }
}

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
        static let speechEngine = "speech.engine"
        // Qwen context has different semantics from the old beam-search score.
        static let hotwords = "speech.qwen.hotwords"
        static let pinyinCorrection = "speech.pinyinCorrection"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var speechEngine: SpeechEngine {
        get { defaults.string(forKey: Keys.speechEngine).flatMap(SpeechEngine.init(rawValue:)) ?? .local }
        set { defaults.set(newValue.rawValue, forKey: Keys.speechEngine) }
    }

    var hotwordsEnabled: Bool {
        get { defaults.object(forKey: Keys.hotwords) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.hotwords) }
    }

    var pinyinCorrectionEnabled: Bool {
        get { defaults.object(forKey: Keys.pinyinCorrection) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.pinyinCorrection) }
    }

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
