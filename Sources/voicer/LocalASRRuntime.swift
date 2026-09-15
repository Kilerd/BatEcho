import Foundation

struct LocalASRRuntime {
    let sourceDirectory: URL
    let directory: URL

    init(sourceDirectory: URL? = nil, directory: URL? = nil) {
        let environment = ProcessInfo.processInfo.environment
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ASR", isDirectory: true)
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("ASR", isDirectory: true)
        self.sourceDirectory = sourceDirectory
            ?? environment["VOICER_ASR_SOURCE"].map { URL(fileURLWithPath: $0) }
            ?? (bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
            ?? checkout
        self.directory = directory
            ?? environment["VOICER_ASR_RUNTIME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/voicer/asr", isDirectory: true)
    }

    var python: URL { directory.appendingPathComponent(".venv/bin/python") }
    var models: URL { directory.appendingPathComponent("models", isDirectory: true) }
    var vocabulary: URL { directory.appendingPathComponent("lexicon.json") }

    var isPrepared: Bool {
        FileManager.default.isExecutableFile(atPath: python.path)
            && ["runtime.json", "lexicon.json", "models/silero_vad.onnx",
                "models/firered/config.json", "models/firered/model.safetensors",
                "models/firered/cmvn.json", "models/firered/dict.txt",
                "models/firered/train_bpe1000.model"].allSatisfy {
                    FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
                }
    }

    var workerConfiguration: LocalASRClient.Configuration {
        .init(executable: python, arguments: ["-u", "-m", "asr_lab.worker",
              "--model-dir", models.path, "--lexicon", vocabulary.path],
              workingDirectory: sourceDirectory)
    }

    var uv: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [home.appendingPathComponent(".local/bin/uv").path,
                          "/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/uv" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}
