import Foundation
import MLX

enum LocalASRError: LocalizedError {
    case notPrepared
    case invalidInput(String)
    case timedOut
    var errorDescription: String? {
        switch self {
        case .notPrepared: return "Prepare the local speech model in Speech Settings first."
        case .invalidInput(let message): return message
        case .timedOut: return "Local speech recognition took too long. Please try a shorter phrase."
        }
    }
}

struct LocalASRResponse: Codable, Sendable {
    var id = UUID().uuidString
    var text: String?
    var rawText: String?
    var ready: Bool?
    var model = "qwen3-asr-0.6b-8bit"
    var engine = "swift-mlx"
    var modelLoadCount = 0
    var elapsedSeconds: Double?
    var confidence: Float?
    var vad: SpeechGateResult?
    var tokens: [Int]?
    var segmentCount: Int?
    enum CodingKeys: String, CodingKey {
        case id, text, ready, model, engine, vad, tokens
        case rawText = "raw_text"
        case modelLoadCount = "model_load_count"
        case elapsedSeconds = "elapsed_s"
        case confidence = "asr_confidence"
        case segmentCount = "segment_count"
    }
}

struct ASROptions: Sendable {
    var hotwords = true
    var correction = true
}

protocol ASRPipeline: AnyObject {
    func warmUp(check: () throws -> Void) throws -> LocalASRResponse
    func transcribe(audio: URL, options: ASROptions, check: () throws -> Void) throws -> LocalASRResponse
    func correct(text: String, check: () throws -> Void) throws -> String
}

/// Thread-safe cancellation token. It never touches MLX arrays from the caller.
final class ASRWork: @unchecked Sendable {
    private let lock = NSLock()
    private var canceled = false
    private let deadline: TimeInterval
    init(timeout: TimeInterval) { deadline = ProcessInfo.processInfo.systemUptime + timeout }
    func cancel() { lock.withLock { canceled = true } }
    func check() throws {
        if lock.withLock({ canceled }) { throw CancellationError() }
        if ProcessInfo.processInfo.systemUptime >= deadline { throw LocalASRError.timedOut }
    }
}

/// Owns the native MLX pipeline on one serial queue, including load/eval/unload.
/// Cancellation is checked between model stages and each decoder/VAD step.
/// A canceled result cannot escape into the next dictation; weights stay warm.
final class LocalASRClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "BatEcho.asr", qos: .userInitiated)
    private let lock = NSLock()
    private var active: [UUID: ASRWork] = [:] // protected by lock
    private var pipeline: ASRPipeline?      // accessed only on queue
    private let factory: () -> ASRPipeline
    private let timeout: TimeInterval

    init(runtime: LocalASRRuntime = LocalASRRuntime(), timeout: TimeInterval = 120,
         factory: (() -> ASRPipeline)? = nil) {
        self.factory = factory ?? { NativeASRPipeline(runtime: runtime) }
        self.timeout = timeout
    }

    func warmUp() async throws { _ = try await perform { try $0.warmUp(check: $1) } }

    func transcribe(audio: URL, hotwords: Bool,
                    correction: Bool = true) async throws -> LocalASRResponse {
        let options = ASROptions(hotwords: hotwords, correction: correction)
        return try await perform { try $0.transcribe(audio: audio, options: options, check: $1) }
    }

    func correct(text: String) async throws -> String {
        try await perform { try $0.correct(text: text, check: $1) }
    }

    func shutdown() async {
        lock.withLock { active.values.forEach { $0.cancel() } }
        await withCheckedContinuation { continuation in
            queue.async { self.pipeline = nil; continuation.resume() }
        }
    }

    private func perform<T>(_ body: @escaping (ASRPipeline, () throws -> Void) throws -> T) async throws -> T {
        let work = ASRWork(timeout: timeout)
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.withLock { active[id] = work }
                queue.async {
                    defer { _ = self.lock.withLock { self.active.removeValue(forKey: id) } }
                    do {
                        try work.check()
                        if self.pipeline == nil { self.pipeline = self.factory() }
                        let result = try MLX.withError { error in
                            try body(self.pipeline!) {
                                try error.check()
                                try work.check()
                            }
                        }
                        try work.check()
                        continuation.resume(returning: result)
                    } catch {
                        // Discard an invalid GPU state; user/input errors and
                        // ordinary cancellation can keep the model warm.
                        if error is MLXError { self.pipeline = nil }
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: { work.cancel() }
    }
}
