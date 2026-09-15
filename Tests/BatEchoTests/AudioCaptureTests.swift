import AVFoundation
import XCTest
@testable import BatEcho

final class AudioCaptureTests: XCTestCase {
    func testNativeRateStereoRecordingIsFinalizedAndDeleted() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let capture = try AudioCapture(format: format)
        defer { capture.discard() }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        for channel in 0..<2 {
            for frame in 0..<4800 { buffer.floatChannelData![channel][frame] = 0.25 }
        }
        try capture.append(buffer)
        capture.finish()
        let saved = try AVAudioFile(forReading: capture.url)
        XCTAssertEqual(saved.processingFormat.sampleRate, 48000)
        XCTAssertEqual(saved.processingFormat.channelCount, 2)
        XCTAssertEqual(saved.length, 4800)
        let attributes = try FileManager.default.attributesOfItem(atPath: capture.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        capture.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.url.path))
    }

    func testOverlongRecordingIsRejectedRatherThanSilentlyClipped() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let capture = try AudioCapture(format: format)
        defer { capture.discard() }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480001)!
        buffer.frameLength = 480001
        XCTAssertThrowsError(try capture.append(buffer))
    }
}
