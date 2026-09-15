import AVFoundation
import Foundation
import Speech

enum TranscriberError: LocalizedError {
    case recognizerUnavailable
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "Speech recognizer is unavailable for the selected language."
        case .microphoneUnavailable:
            return "No usable microphone input was found."
        }
    }
}

/// Streams microphone audio into SFSpeechRecognizer and publishes partial
/// transcripts plus a smoothed RMS level for the waveform display.
/// All callbacks are delivered on the main queue.
@MainActor
final class SpeechTranscriber: SpeechTranscribing {
    var onPartial: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latestText = ""
    private var finished = true
    private var finalFallback: DispatchWorkItem?

    func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { _ in }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    func start(localeID: String) throws {
        teardown()
        latestText = ""
        finished = false

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)),
              recognizer.isAvailable
        else {
            finished = true
            throw TranscriberError.recognizerUnavailable
        }
        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        self.request = request

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            finished = true
            throw TranscriberError.microphoneUnavailable
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            request.append(buffer)
            self.publishLevel(buffer)
        }
        engine.prepare()
        try engine.start()
        audioEngine = engine

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    guard !self.finished else { return }
                    self.latestText = text
                    self.onPartial?(text)
                    if result.isFinal {
                        self.deliverFinal()
                    }
                }
            }
            if error != nil {
                DispatchQueue.main.async { self.deliverFinal() }
            }
        }
    }

    /// Stops capturing and waits (bounded) for the recognizer's final result.
    func stop() {
        stopAudio()
        request?.endAudio()
        let fallback = DispatchWorkItem { [weak self] in self?.deliverFinal() }
        finalFallback = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: fallback)
    }

    /// Aborts the session without delivering a final result.
    func cancel() {
        finished = true
        teardown()
    }

    private func deliverFinal() {
        guard !finished else { return }
        finished = true
        let text = latestText
        teardown()
        onFinal?(text)
    }

    private func stopAudio() {
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
    }

    private func teardown() {
        finalFallback?.cancel()
        finalFallback = nil
        stopAudio()
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
    }

    nonisolated private func publishLevel(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        var sum: Float = 0
        for i in 0..<frames {
            let sample = channel[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frames))
        let db = 20 * log10(max(rms, 1e-7))
        // Map roughly -50 dB (silence) ... -6 dB (loud speech) into 0...1.
        let level = max(0, min(1, (db + 50) / 44))

        DispatchQueue.main.async { [weak self] in
            guard let self, !self.finished else { return }
            self.onLevel?(level)
        }
    }
}
