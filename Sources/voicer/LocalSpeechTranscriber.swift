import AVFoundation
import Foundation

/// Saves native-rate microphone buffers as CAF. The Python reader converts
/// channels/sample rate once, after recording, using the tested ASR audio path.
// Only the immutable URL escapes; all mutable writer state is protected by lock.
final class AudioCapture: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var frames: AVAudioFramePosition = 0
    private let maximumFrames: AVAudioFramePosition

    init(format: AVAudioFormat, directory: URL = FileManager.default.temporaryDirectory) throws {
        url = directory.appendingPathComponent("voicer-\(UUID().uuidString).caf")
        maximumFrames = AVAudioFramePosition(format.sampleRate * 30)
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        file = try AVAudioFile(forWriting: url, settings: settings,
                              commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let file else { return }
        guard frames + AVAudioFramePosition(buffer.frameLength) <= maximumFrames else {
            self.file = nil
            throw LocalASRError.worker("Recording limit reached. Please dictate up to 30 seconds at a time.")
        }
        try file.write(from: buffer)
        frames += AVAudioFramePosition(buffer.frameLength)
    }

    func finish() {
        lock.lock()
        file = nil
        lock.unlock()
    }

    func discard() {
        finish()
        try? FileManager.default.removeItem(at: url)
    }

    deinit { discard() }
}

@MainActor
final class LocalSpeechTranscriber: SpeechTranscribing {
    var onPartial: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    private let client: LocalASRClient
    private let hotwords: Bool
    private let score: Double
    private let correction: Bool
    private var engine: AVAudioEngine?
    private var capture: AudioCapture?
    private var operation: Task<Void, Never>?
    private var finished = true
    private var session = UUID()

    init(client: LocalASRClient, hotwords: Bool, score: Double, correction: Bool) {
        self.client = client
        self.hotwords = hotwords
        self.score = score
        self.correction = correction
    }

    func requestAuthorization() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    func start(localeID: String) throws {
        cancel()
        let token = UUID()
        session = token
        let audio = AVAudioEngine()
        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw TranscriberError.microphoneUnavailable
        }
        let recording = try AudioCapture(format: format)
        capture = recording
        finished = false
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            do { try recording.append(buffer) }
            catch {
                DispatchQueue.main.async { self?.fail(error, session: token) }
                return
            }
            let level = Self.level(buffer)
            DispatchQueue.main.async {
                guard let self, !self.finished, self.session == token else { return }
                self.onLevel?(level)
            }
        }
        engine = audio
        do {
            audio.prepare()
            try audio.start()
        } catch {
            cancel()
            throw error
        }
    }

    func stop() {
        guard !finished, let recording = capture else { return }
        stopAudio()
        recording.finish()
        capture = nil
        let token = session
        let client = client, hotwords = hotwords, score = score, correction = correction
        operation = Task { @MainActor [weak self] in
            defer { recording.discard() }
            do {
                let result = try await client.transcribe(audio: recording.url, hotwords: hotwords,
                                                         score: score, correction: correction)
                try Task.checkCancellation()
                guard let self, !self.finished, self.session == token else { return }
                self.finished = true
                self.operation = nil
                self.onFinal?(result.text ?? "")
            } catch is CancellationError {
                // Canceled sessions must never inject their late result.
            } catch {
                self?.fail(error, session: token)
            }
        }
    }

    func cancel() {
        finished = true
        session = UUID()
        operation?.cancel()
        operation = nil
        stopAudio()
        capture?.discard()
        capture = nil
    }

    private func stopAudio() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    private func fail(_ error: Error, session token: UUID) {
        guard !finished, session == token else { return }
        cancel()
        onError?(error)
    }

    nonisolated private static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += channel[index] * channel[index] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        return max(0, min(1, (20 * log10(max(rms, 1e-7)) + 50) / 44))
    }
}
