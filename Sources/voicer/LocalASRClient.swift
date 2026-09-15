import Foundation
import Darwin

enum LocalASRError: LocalizedError {
    case notPrepared
    case worker(String)
    case disconnected
    case invalidResponse
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notPrepared: return "Prepare the local speech model in Speech Settings first."
        case .worker(let message): return message
        case .disconnected: return "Local speech recognition stopped. Please try again."
        case .invalidResponse: return "Local speech recognition returned an invalid response."
        case .timedOut: return "Local speech recognition took too long. Please try a shorter phrase."
        }
    }
}

struct LocalASRResponse: Codable {
    struct WorkerError: Codable {
        let code: String
        let message: String
    }

    let id: String?
    let text: String?
    let rawText: String?
    let ready: Bool?
    let model: String?
    let modelLoadCount: Int?
    let elapsedSeconds: Double?
    let error: WorkerError?

    enum CodingKeys: String, CodingKey {
        case id, text, ready, model, error
        case rawText = "raw_text"
        case modelLoadCount = "model_load_count"
        case elapsedSeconds = "elapsed_s"
    }
}

/// Owns one warm Python process. Request IDs prevent late responses from a
/// canceled recording from being delivered to a later recording.
actor LocalASRClient {
    struct Configuration {
        let executable: URL
        let arguments: [String]
        let workingDirectory: URL
        var timeoutSeconds: Double = 120
    }

    private struct Request: Encodable {
        let id: String
        let type: String
        let audio: String?
        let hotwords: Bool
        let hotword_score: Double
        let correction: String
    }

    private struct Pending {
        let continuation: CheckedContinuation<LocalASRResponse, Error>
        let timeout: Task<Void, Never>
    }

    private let configuration: Configuration
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var diagnostics: FileHandle?
    private var buffer = Data()
    private var generation = UUID()
    private var pending: [String: Pending] = [:]

    init(configuration: Configuration = LocalASRRuntime().workerConfiguration) {
        self.configuration = configuration
    }

    func warmUp() async throws {
        let result = try await send(type: "warmup")
        guard result.ready == true else { throw LocalASRError.invalidResponse }
    }

    func transcribe(audio: URL, hotwords: Bool, score: Double = 4,
                    correction: Bool = true) async throws -> LocalASRResponse {
        let result = try await send(type: "transcribe", audio: audio.path,
                                    hotwords: hotwords, score: score, correction: correction)
        guard result.text != nil else { throw LocalASRError.invalidResponse }
        return result
    }

    func shutdown() {
        disconnect(CancellationError())
    }

    private func startIfNeeded() throws {
        if process?.isRunning == true { return }
        if process != nil { disconnect(LocalASRError.disconnected) }
        guard FileManager.default.isExecutableFile(atPath: configuration.executable.path) else {
            throw LocalASRError.notPrepared
        }
        let child = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        // A child can exit between isRunning and write. Convert a broken pipe
        // into a request error instead of letting SIGPIPE terminate the app.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let token = UUID()
        generation = token
        child.executableURL = configuration.executable
        child.arguments = configuration.arguments
        child.currentDirectoryURL = configuration.workingDirectory
        child.environment = ProcessInfo.processInfo.environment.merging([
            "PYTHONUNBUFFERED": "1", "TOKENIZERS_PARALLELISM": "false",
            "PYTHONDONTWRITEBYTECODE": "1"
        ]) { _, new in new }
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        stderr.fileHandleForReading.readabilityHandler = { handle in
            // Drain diagnostics so a full stderr pipe cannot stall inference.
            // Do not log transcripts or arbitrary model diagnostics to the system log.
            _ = handle.availableData
        }
        do {
            try child.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        process = child
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        diagnostics = stderr.fileHandleForReading
        // Await each delivery before the next pipe read. Launching an unrelated
        // Task for each readability callback would not guarantee chunk order.
        let reader = stdout.fileHandleForReading
        Task.detached { [weak self] in
            while true {
                // read(upToCount:) may wait to fill its requested byte count
                // on a pipe. availableData returns the next available chunk.
                let bytes = reader.availableData
                await self?.receive(bytes, generation: token)
                if bytes.isEmpty { return }
            }
        }
    }

    private func send(type: String, audio: String? = nil, hotwords: Bool = false,
                      score: Double = 4, correction: Bool = true) async throws -> LocalASRResponse {
        try Task.checkCancellation()
        try startIfNeeded()
        let id = UUID().uuidString
        let request = Request(id: id, type: type, audio: audio, hotwords: hotwords,
                              hotword_score: score, correction: correction ? "context" : "none")
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let seconds = configuration.timeoutSeconds
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
                    catch { return }
                    await self?.expire(id)
                }
                pending[id] = Pending(continuation: continuation, timeout: timeout)
                do { try input?.write(contentsOf: data) }
                catch { disconnect(error) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func receive(_ bytes: Data, generation token: UUID) {
        guard token == generation else { return }
        guard !bytes.isEmpty else {
            disconnect(LocalASRError.disconnected)
            return
        }
        buffer.append(bytes)
        guard buffer.count <= 1024 * 1024 else {
            disconnect(LocalASRError.invalidResponse)
            return
        }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard let response = try? JSONDecoder().decode(LocalASRResponse.self, from: line),
                  let id = response.id else {
                disconnect(LocalASRError.invalidResponse)
                return
            }
            guard let request = pending.removeValue(forKey: id) else { continue }
            request.timeout.cancel()
            if let error = response.error {
                request.continuation.resume(throwing: LocalASRError.worker(error.message))
            } else {
                request.continuation.resume(returning: response)
            }
        }
    }

    private func expire(_ id: String) {
        guard pending[id] != nil else { return }
        disconnect(LocalASRError.timedOut)
    }

    private func cancel(_ id: String) {
        guard pending[id] != nil else { return }
        // A running Metal decode cannot consume another stdin message. Stop
        // this worker; the next request creates a fresh, isolated generation.
        disconnect(CancellationError())
    }

    private func disconnect(_ error: Error) {
        generation = UUID()
        output?.readabilityHandler = nil
        diagnostics?.readabilityHandler = nil
        process?.terminationHandler = nil
        try? input?.close()
        input = nil
        output = nil
        diagnostics = nil
        buffer.removeAll(keepingCapacity: false)
        let child = process
        process = nil
        if let child, child.isRunning {
            child.terminate()
            Task.detached {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timeout.cancel()
            request.continuation.resume(throwing: error)
        }
    }
}
