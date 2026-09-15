import Foundation
import CryptoKit
import Darwin

struct LocalASRRuntime: Sendable {
    let directory: URL
    static var resources: URL { Bundle.module.resourceURL!.appendingPathComponent("ASRResources") }
    init(directory: URL? = nil) {
        self.directory = directory
            ?? ProcessInfo.processInfo.environment["VOICER_ASR_RUNTIME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/voicer/asr", isDirectory: true)
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
    static let assets: [Asset] = {
        let fireRed = "mlx-community/FireRedASR2-AED-mlx"
        let revision = "f3212eacfa49b851130b97c63653c8e06ee09bdb"
        let silero = "mlx-community/silero-vad-v6"
        let vadRevision = "2ebf4a5e10726a2e78ddd4d70eedfb6f1c33eb06"
        return [
            Asset(repository: fireRed, revision: revision, path: "firered/config.json", size: 369, sha256: "ef3be4345675bf62b873de2b256b60e92fcfe44f95b3d9d810cb90a29ea69e91"),
            Asset(repository: fireRed, revision: revision, path: "firered/cmvn.json", size: 3255, sha256: "3f702336649609864b8a7c91ec3d25ae36be15f2d70f37cb35afeebf178be584"),
            Asset(repository: fireRed, revision: revision, path: "firered/dict.txt", size: 79172, sha256: "1bc613de2112d257e61a349c3e72d1b1a9cf19c33d3ca954197ad2171e5ea07b"),
            Asset(repository: fireRed, revision: revision, path: "firered/train_bpe1000.model", size: 251707, sha256: "473bbc157cb4eade2059b30a3c877a1c29bd50cadbfbed869ae36eeade7fee07"),
            Asset(repository: fireRed, revision: revision, path: "firered/model.safetensors", size: 4565783672, sha256: "e91fa08c58f07accd1803c8f0a9ffce24f4b3952c9fbc8ea476a82873e0386d4"),
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
        let manifest: [String: Any] = ["schema": 2, "engine": "swift-mlx", "mlx_swift": "0.31.6",
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
