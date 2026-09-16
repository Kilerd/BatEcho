import Foundation
import CryptoKit
import Darwin

struct LocalASRRuntime: Sendable {
    let directory: URL
    static var resources: URL { Bundle.module.resourceURL!.appendingPathComponent("ASRResources") }
    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }
    static func defaultDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        for key in ["BATECHO_ASR_RUNTIME", "VOICER_ASR_RUNTIME"] {
            if let path = environment[key], !path.isEmpty { return URL(fileURLWithPath: path) }
        }
        // Preserve downloaded weights and personal vocabulary from voicer.
        return home.appendingPathComponent("Library/Application Support/voicer/asr", isDirectory: true)
    }
    var models: URL { directory.appendingPathComponent("models", isDirectory: true) }
    var vocabulary: URL { directory.appendingPathComponent("lexicon.json") }
    var isPrepared: Bool {
        FileManager.default.fileExists(atPath: vocabulary.path) && Self.assets.allSatisfy {
            (try? models.appendingPathComponent($0.path).resourceValues(forKeys: [.fileSizeKey]).fileSize) == $0.size
        }
    }
    struct Asset: Sendable {
        let repository: String
        let revision: String
        let path: String
        let size: Int
        let sha256: String
        var url: URL {
            URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(URL(fileURLWithPath: path).lastPathComponent)")!
        }
    }
    static let modelDirectoryName = "qwen3-asr-0.6b-8bit"

    static let assets: [Asset] = {
        let silero = "mlx-community/silero-vad-v6"
        let vadRevision = "2ebf4a5e10726a2e78ddd4d70eedfb6f1c33eb06"
        return [
            Asset(repository: "mlx-community/Qwen3-ASR-0.6B-8bit", revision: "89e96d92ba34aca20b3e29fb10cc284097d1219f", path: "qwen3-asr-0.6b-8bit/config.json", size: 7187, sha256: "5d104a945fed08728ab010f12bf3ce5ab4d0794bba276d81bff5bd83ae9d2be0"),
            Asset(repository: "mlx-community/Qwen3-ASR-0.6B-8bit", revision: "89e96d92ba34aca20b3e29fb10cc284097d1219f", path: "qwen3-asr-0.6b-8bit/vocab.json", size: 2776833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
            Asset(repository: "mlx-community/Qwen3-ASR-0.6B-8bit", revision: "89e96d92ba34aca20b3e29fb10cc284097d1219f", path: "qwen3-asr-0.6b-8bit/merges.txt", size: 1671853, sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
            Asset(repository: "mlx-community/Qwen3-ASR-0.6B-8bit", revision: "89e96d92ba34aca20b3e29fb10cc284097d1219f", path: "qwen3-asr-0.6b-8bit/tokenizer_config.json", size: 12487, sha256: "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"),
            Asset(repository: "mlx-community/Qwen3-ASR-0.6B-8bit", revision: "89e96d92ba34aca20b3e29fb10cc284097d1219f", path: "qwen3-asr-0.6b-8bit/model.safetensors", size: 1006229426, sha256: "b5bfe4abc1b4c6e58b633096682ec2b6297298add1527119936107d211adf0e8"),
            Asset(repository: silero, revision: vadRevision, path: "silero-v6/config.json", size: 463, sha256: "9fe1befb9692a0d4135adadc33f8075ef6d350bd2391b88d750f2c233f97fa0b"),
            Asset(repository: silero, revision: vadRevision, path: "silero-v6/model.safetensors", size: 1237860, sha256: "65b6c5f0293cbc44d109e58bef78b474d9c65dedbee814cf0b90ef5f0d9150ff")
        ]
    }()

    /// Download to disk, verify size/SHA256, then atomically rename each file.
    /// No Python environment is needed; preserve existing personal vocabulary.
    func prepare(progress: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appendingPathComponent("native-setup.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw LocalASRError.invalidInput("Cannot open model setup lock.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw LocalASRError.invalidInput("Model preparation is already running.")
        }
        defer { flock(descriptor, LOCK_UN) }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 7200
        config.timeoutIntervalForRequest = 120
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        for (index, asset) in Self.assets.enumerated() {
            try Task.checkCancellation()
            let destination = models.appendingPathComponent(asset.path)
            progress("Checking \(asset.path) (\(index + 1)/\(Self.assets.count))…")
            if try Self.matches(destination, asset: asset) { continue }
            progress("Downloading \(asset.path) (\(index + 1)/\(Self.assets.count))…")
            let (temporary, response) = try await session.download(from: asset.url)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  try Self.matches(temporary, asset: asset) else {
                throw LocalASRError.invalidInput("Model download failed verification: \(asset.path)")
            }
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staged = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).download")
            defer { try? FileManager.default.removeItem(at: staged) }
            try FileManager.default.copyItem(at: temporary, to: staged)
            guard rename(staged.path, destination.path) == 0 else {
                throw LocalASRError.invalidInput("Cannot save model file: \(asset.path)")
            }
        }
        if !FileManager.default.fileExists(atPath: vocabulary.path) {
            let data = try Data(contentsOf: Self.resources.appendingPathComponent("lexicon.json"))
            try data.write(to: vocabulary, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vocabulary.path)
        }
        let manifest: [String: Any] = ["schema": 3, "engine": "swift-mlx", "model": Self.modelDirectoryName, "mlx_swift": "0.31.6",
                                      "assets": Self.assets.map { ["path": $0.path, "revision": $0.revision, "sha256": $0.sha256] }]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("native-runtime.json"), options: .atomic)
        progress("Local model is prepared.")
    }
    static func matches(_ url: URL, asset: Asset) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == asset.size else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == asset.sha256
    }
}
