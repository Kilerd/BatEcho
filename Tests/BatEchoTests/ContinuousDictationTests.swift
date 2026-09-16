import AVFoundation
import XCTest
@testable import BatEcho

final class SegmentedAudioCaptureTests: XCTestCase {
    private func buffer(_ format: AVAudioFormat, start: Int, frames: Int, silent: Bool = false) -> AVAudioPCMBuffer {
        let value = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        value.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(format.channelCount) {
            for index in 0..<frames {
                value.floatChannelData![channel][index] = silent ? 0 : Float((start + index) % 97 + channel + 10) / 200
            }
        }
        return value
    }

    func testTwoMinutesHaveBoundedSegmentsAndNoMissingSamples() async throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 2)!
        let capture = try SegmentedAudioCapture(format: format)
        defer { capture.discard() }
        let length = 132 * 16000
        for start in stride(from: 0, to: length, by: 4096) {
            try capture.append(buffer(format, start: start, frames: min(4096, length - start)))
        }
        capture.finish()
        var end: Int64 = 0
        var count = 0
        for try await segment in capture.segments {
            let file = try AVAudioFile(forReading: segment.recording.url)
            XCTAssertLessThanOrEqual(file.length, 25 * 16000)
            XCTAssertEqual(file.length, segment.endFrame - segment.startFrame)
            XCTAssertEqual(segment.startFrame, end - segment.overlapFrames)
            XCTAssertEqual(segment.overlapFrames, count == 0 ? 0 : 16000)
            let saved = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: saved)
            for channel in 0..<2 {
                for frame in stride(from: 0, to: Int(saved.frameLength), by: 997) {
                    let expected = Float((Int(segment.startFrame) + frame) % 97 + channel + 10) / 200
                    XCTAssertEqual(saved.floatChannelData![channel][frame], expected)
                }
            }
            end = segment.endFrame
            count += 1
            capture.release(segment)
            XCTAssertFalse(FileManager.default.fileExists(atPath: segment.recording.url.path))
        }
        XCTAssertEqual(count, 6)
        XCTAssertEqual(end, Int64(length))
    }

    func testPausesCutWithoutOverlapAndPreserveTrailingAudio() async throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let capture = try SegmentedAudioCapture(format: format)
        defer { capture.discard() }
        try capture.append(buffer(format, start: 0, frames: 3 * 48000))
        try capture.append(buffer(format, start: 0, frames: 48000, silent: true))
        try capture.append(buffer(format, start: 0, frames: 3 * 48000))
        capture.finish()
        var segments: [AudioSegment] = []
        for try await segment in capture.segments { segments.append(segment) }
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].endFrame, Int64(3.66 * 48000))
        XCTAssertEqual(segments[1].startFrame, segments[0].endFrame)
        XCTAssertEqual(segments[1].endFrame, 7 * 48000)
        XCTAssertTrue(segments.allSatisfy { $0.overlapFrames == 0 })
    }

    func testStopAtForcedBoundaryDoesNotEmitOverlapAlone() async throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let capture = try SegmentedAudioCapture(format: format)
        defer { capture.discard() }
        try capture.append(buffer(format, start: 0, frames: 25 * 16000))
        capture.finish()
        var count = 0
        for try await _ in capture.segments { count += 1 }
        XCTAssertEqual(count, 1)
    }

    func testCancelDeletesQueuedAndUnfinishedRecordings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let capture = try SegmentedAudioCapture(format: format, directory: directory)
        try capture.append(buffer(format, start: 0, frames: 26 * 16000))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
        capture.discard()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        capture.finish()
        try capture.append(buffer(format, start: 0, frames: 20))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}

final class TranscriptAssemblerTests: XCTestCase {
    func testOverlapDeduplicatesChineseAndEnglish() {
        var text = TranscriptAssembler()
        text.append("明天上午十点开会", overlapDuration: 0)
        text.append("十点开会讨论 kubernetes", overlapDuration: 1)
        text.append("Kubernetes and postgresql", overlapDuration: 1)
        XCTAssertEqual(text.text, "明天上午十点开会讨论 kubernetes and postgresql")
    }

    func testIntentionalRepeatsSurvivePausesAndSilentSegments() {
        var text = TranscriptAssembler()
        text.append("再试一次", overlapDuration: 0)
        text.append("再试一次", overlapDuration: 0)
        text.append("", overlapDuration: 1)
        text.append("再试一次", overlapDuration: 1)
        XCTAssertEqual(text.text, "再试一次再试一次再试一次")
    }

    func testOverlappedEnglishFragmentIsRestored() {
        var text = TranscriptAssembler()
        text.append("we use kuber", overlapDuration: 0)
        text.append("kubernetes for deployment", overlapDuration: 1)
        XCTAssertEqual(text.text, "we use kubernetes for deployment")
    }

    func testSingleAmbiguousCharacterIsPreserved() {
        var text = TranscriptAssembler()
        text.append("看看", overlapDuration: 0)
        text.append("看这个例子", overlapDuration: 1)
        XCTAssertEqual(text.text, "看看看这个例子")
    }
}

private final class DictationPipeline: ASRPipeline {
    var calls = 0
    var corrected: [String] = []
    var onInference: ((Int) -> Void)?
    var onAudio: ((URL) throws -> Void)?
    func warmUp(check: () throws -> Void) throws -> LocalASRResponse { .init(ready: true) }
    func transcribe(audio: URL, options: ASROptions, check: () throws -> Void) throws -> LocalASRResponse {
        XCTAssertFalse(Thread.isMainThread)
        XCTAssertFalse(options.correction)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        try onAudio?(audio)
        calls += 1
        onInference?(calls)
        try check()
        let text = calls == 1 ? "这个项目由同事景" : "珩负责"
        return .init(text: text, rawText: text, modelLoadCount: 1)
    }
    func correct(text: String, check: () throws -> Void) throws -> String {
        try check()
        corrected.append(text)
        return text.replacingOccurrences(of: "景珩", with: "璟珩")
    }
}

final class ContinuousTranscriptionTests: XCTestCase {
    func testPCM16FileWithPartialFinalReadFinishesWithoutReadingPastEOF() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let frames: AVAudioFrameCount = 48174 // includes a partial 4096-frame read
        // Write exact PCM bytes so this test also covers the final 46 samples,
        // without relying on an audio converter's buffered file writer.
        var wave = Data()
        func text(_ value: String) { wave.append(contentsOf: value.utf8) }
        func integer<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { wave.append(contentsOf: $0) }
        }
        text("RIFF"); integer(UInt32(36 + frames * 2)); text("WAVEfmt ")
        integer(UInt32(16)); integer(UInt16(1)); integer(UInt16(1))
        integer(UInt32(16000)); integer(UInt32(32000)); integer(UInt16(2)); integer(UInt16(16))
        text("data"); integer(UInt32(frames * 2))
        for _ in 0..<frames { integer(Int16(6553)) }
        try wave.write(to: url)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, AVAudioFramePosition(frames))
        let pipeline = DictationPipeline()
        pipeline.onAudio = { audio in XCTAssertEqual(try NativeAudio.read(audio).count, Int(frames)) }
        let client = LocalASRClient(factory: { pipeline })
        let result = try await ContinuousTranscription.transcribeFile(url, client: client, options: .init(correction: false))
        XCTAssertEqual(result.segmentCount, 1)
        XCTAssertEqual(pipeline.calls, 1)
        await client.shutdown()
    }

    private func append(_ capture: SegmentedAudioCapture, frames: Int = 6400) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        buffer.floatChannelData![0].initialize(repeating: 0.2, count: frames)
        try capture.append(buffer)
    }

    private func capture() throws -> SegmentedAudioCapture {
        try .init(format: AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!,
                  configuration: .init(maximumDuration: 0.4, minimumDuration: 0.2,
                                       pauseDuration: 0.1, overlapDuration: 0))
    }

    func testRecognitionStartsWhileRecordingAndCorrectionRunsOnceOnWholeText() async throws {
        let capture = try capture()
        defer { capture.discard() }
        let pipeline = DictationPipeline()
        let client = LocalASRClient(factory: { pipeline })
        let preview = expectation(description: "preview before recording stops")
        let task = Task {
            try await ContinuousTranscription.run(capture: capture, client: client, options: .init()) { text in
                if text == "这个项目由同事景" { preview.fulfill() }
            }
        }
        try append(capture)
        await fulfillment(of: [preview], timeout: 3)
        XCTAssertTrue(pipeline.corrected.isEmpty)
        try append(capture)
        capture.finish()
        let result = try await task.value
        XCTAssertEqual(result.rawText, "这个项目由同事景珩负责")
        XCTAssertEqual(result.text, "这个项目由同事璟珩负责")
        XCTAssertEqual(pipeline.corrected, [result.rawText!])
        XCTAssertEqual(result.segmentCount, 2)
        XCTAssertEqual(result.modelLoadCount, 1)
        await client.shutdown()
    }

    func testCancellationSuppressesLateResultAndQueuedSegments() async throws {
        let capture = try capture()
        defer { capture.discard() }
        let started = expectation(description: "inference started")
        let release = DispatchSemaphore(value: 0)
        let pipeline = DictationPipeline()
        pipeline.onInference = { call in if call == 1 { started.fulfill(); release.wait() } }
        let client = LocalASRClient(factory: { pipeline })
        let task = Task { try await ContinuousTranscription.run(capture: capture, client: client, options: .init()) }
        try append(capture, frames: 19200)
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        capture.discard()
        release.signal()
        do { _ = try await task.value; XCTFail("Canceled recording escaped") }
        catch is CancellationError { }
        XCTAssertEqual(pipeline.calls, 1)
        XCTAssertTrue(pipeline.corrected.isEmpty)
        await client.shutdown()
    }
}
