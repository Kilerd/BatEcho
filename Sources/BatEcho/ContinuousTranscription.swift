import AVFoundation
import Foundation

enum ContinuousTranscription {
    /// One consumer keeps inference ordered and reuses the warm model. Preview
    /// text is never injected; vocabulary correction sees the assembled text.
    static func run(capture: SegmentedAudioCapture, client: LocalASRClient, options: ASROptions,
                    onPartial: (@MainActor @Sendable (String) -> Void)? = nil) async throws -> LocalASRResponse {
        var assembler = TranscriptAssembler()
        var result = LocalASRResponse(text: "", rawText: "")
        var count = 0
        var elapsed: Double = 0
        var gate = SpeechGateResult(hasSpeech: false, maxProbability: 0, longestSpeechMS: 0)
        for try await segment in capture.segments {
            defer { capture.release(segment) }
            try Task.checkCancellation()
            let response = try await client.transcribe(audio: segment.recording.url, hotwords: options.hotwords,
                                                       correction: false)
            try Task.checkCancellation()
            let previous = assembler.text
            assembler.append(response.rawText ?? response.text ?? "", overlapDuration: segment.overlapDuration)
            result = response
            count += 1
            elapsed += response.elapsedSeconds ?? 0
            if let value = response.vad {
                gate = .init(hasSpeech: gate.hasSpeech || value.hasSpeech,
                             maxProbability: max(gate.maxProbability, value.maxProbability),
                             longestSpeechMS: max(gate.longestSpeechMS, value.longestSpeechMS))
            }
            if assembler.text != previous { await onPartial?(assembler.text) }
        }
        try Task.checkCancellation()
        result.rawText = assembler.text
        let started = ProcessInfo.processInfo.systemUptime
        result.text = options.correction && !assembler.text.isEmpty
            ? try await client.correct(text: assembler.text) : assembler.text
        try Task.checkCancellation()
        result.segmentCount = count
        result.elapsedSeconds = elapsed + ProcessInfo.processInfo.systemUptime - started
        result.vad = gate
        if count != 1 { result.tokens = nil; result.confidence = nil }
        return result
    }

    /// Streams files through the same segmentation and assembly as microphone
    /// capture, without allocating a buffer for the entire recording.
    static func transcribeFile(_ url: URL, client: LocalASRClient, options: ASROptions,
                               configuration: AudioSegmentation = .init()) async throws -> LocalASRResponse {
        let format = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false).processingFormat
        let capture = try SegmentedAudioCapture(format: format, configuration: configuration)
        let producer = Task.detached(priority: .userInitiated) {
            do {
                let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else {
                    throw LocalASRError.invalidInput("Cannot read audio.")
                }
                while file.framePosition < file.length {
                    try Task.checkCancellation()
                    let remaining = AVAudioFrameCount(min(4096, file.length - file.framePosition))
                    try file.read(into: buffer, frameCount: remaining)
                    if buffer.frameLength == 0 { break }
                    try capture.append(buffer)
                }
                capture.finish()
            } catch { capture.fail(error) }
        }
        return try await withTaskCancellationHandler {
            do {
                let response = try await run(capture: capture, client: client, options: options)
                await producer.value
                capture.discard()
                return response
            } catch {
                producer.cancel()
                capture.discard()
                await producer.value
                throw error
            }
        } onCancel: {
            producer.cancel()
            capture.discard()
        }
    }
}
