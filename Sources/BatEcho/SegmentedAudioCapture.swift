import AVFoundation
import Foundation

struct AudioSegmentation: Sendable {
    var maximumDuration: TimeInterval = 25
    var minimumDuration: TimeInterval = 2
    var pauseDuration: TimeInterval = 0.65
    var overlapDuration: TimeInterval = 1
    var silenceThreshold: Float = 0.008
}

struct AudioSegment: Sendable {
    let recording: AudioCapture
    let startFrame: AVAudioFramePosition
    let endFrame: AVAudioFramePosition
    let overlapFrames: AVAudioFramePosition
    let sampleRate: Double

    var overlapDuration: TimeInterval { Double(overlapFrames) / sampleRate }
}

/// The microphone and file reader share this producer. Only a short overlap is
/// held in memory; completed segments live in private files until consumed.
/// Energy chooses pauses, but never discards audio. Silero still decides whether
/// each segment contains speech on the inference queue.
final class SegmentedAudioCapture: @unchecked Sendable {
    let segments: AsyncThrowingStream<AudioSegment, Error>

    private struct Window {
        let buffer: AVAudioPCMBuffer
        let speech: Bool
        var frames: Int { Int(buffer.frameLength) }
    }

    private let lock = NSLock()
    private let continuation: AsyncThrowingStream<AudioSegment, Error>.Continuation
    private let format: AVAudioFormat
    private let directory: URL
    private let maximumFrames: Int
    private let minimumFrames: Int
    private let pauseFrames: Int
    private let overlapFrames: Int
    private let windowFrames: Int
    private let silenceThreshold: Float
    private var current: AudioCapture?
    private var outstanding: [URL: AudioCapture] = [:]
    private var tail: [Window] = []
    private var tailFrames = 0
    private var prefix: [Window] = []
    private var totalFrames: AVAudioFramePosition = 0
    private var startFrame: AVAudioFramePosition = 0
    private var currentOverlap: AVAudioFramePosition = 0
    private var currentFrames = 0
    private var silentFrames = 0
    private var hasSpeech = false
    private var closed = false

    init(format: AVAudioFormat, configuration: AudioSegmentation = .init(),
         directory: URL = FileManager.default.temporaryDirectory) throws {
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              (8000...192000).contains(format.sampleRate), (1...8).contains(format.channelCount),
              configuration.maximumDuration.isFinite,
              (0.1...NativeAudio.maximumSegmentDuration).contains(configuration.maximumDuration),
              configuration.minimumDuration > 0,
              configuration.minimumDuration <= configuration.maximumDuration,
              configuration.pauseDuration > 0,
              configuration.pauseDuration <= configuration.maximumDuration,
              configuration.overlapDuration >= 0,
              configuration.overlapDuration < configuration.maximumDuration / 2,
              configuration.silenceThreshold.isFinite,
              configuration.silenceThreshold >= 0 else {
            throw LocalASRError.invalidInput("Unsupported recording format or segmentation settings.")
        }
        self.format = format
        self.directory = directory
        maximumFrames = Int(format.sampleRate * configuration.maximumDuration)
        minimumFrames = Int(format.sampleRate * configuration.minimumDuration)
        pauseFrames = max(1, Int(format.sampleRate * configuration.pauseDuration))
        overlapFrames = Int(format.sampleRate * configuration.overlapDuration)
        windowFrames = max(1, Int(format.sampleRate * 0.02))
        silenceThreshold = configuration.silenceThreshold
        var sink: AsyncThrowingStream<AudioSegment, Error>.Continuation!
        segments = AsyncThrowingStream { sink = $0 }
        continuation = sink
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        guard buffer.format.isEqual(format) else {
            throw LocalASRError.invalidInput("The recording format changed during dictation.")
        }
        var offset = 0
        while offset < Int(buffer.frameLength) {
            try openSegmentIfNeeded()
            let count = min(windowFrames, maximumFrames - currentFrames, Int(buffer.frameLength) - offset)
            let slice = try Self.slice(buffer, offset: offset, count: count)
            let window = Window(buffer: slice, speech: try Self.energy(slice) >= silenceThreshold)
            try current!.append(slice)
            currentFrames += count
            totalFrames += AVAudioFramePosition(count)
            offset += count
            observe(window)
            try retainTail(window)
            if hasSpeech && currentFrames >= minimumFrames && silentFrames >= pauseFrames {
                emit(overlapping: false)
            } else if currentFrames == maximumFrames {
                emit(overlapping: true)
            }
        }
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        emit(overlapping: false)
        closed = true
        continuation.finish()
    }

    func fail(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        current?.discard()
        current = nil
        tail = []
        prefix = []
        continuation.finish(throwing: error)
    }

    func release(_ segment: AudioSegment) {
        lock.lock()
        outstanding.removeValue(forKey: segment.recording.url)
        lock.unlock()
        segment.recording.discard()
    }

    func discard() {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        continuation.finish(throwing: CancellationError())
        current?.discard()
        current = nil
        outstanding.values.forEach { $0.discard() }
        outstanding.removeAll()
        tail = []
        prefix = []
    }

    deinit { discard() }

    private func openSegmentIfNeeded() throws {
        guard current == nil else { return }
        current = try AudioCapture(format: format, directory: directory)
        currentFrames = 0
        silentFrames = 0
        hasSpeech = false
        tail = prefix
        tailFrames = prefix.reduce(0) { $0 + $1.frames }
        currentOverlap = AVAudioFramePosition(tailFrames)
        startFrame = totalFrames - currentOverlap
        for window in prefix {
            try current!.append(window.buffer)
            currentFrames += window.frames
            observe(window)
        }
        prefix = []
    }

    private func observe(_ window: Window) {
        if window.speech { hasSpeech = true; silentFrames = 0 }
        else { silentFrames += window.frames }
    }

    private func retainTail(_ window: Window) throws {
        guard overlapFrames > 0 else { return }
        tail.append(window)
        tailFrames += window.frames
        while let first = tail.first, tailFrames - first.frames >= overlapFrames {
            tailFrames -= first.frames
            tail.removeFirst()
        }
        if tailFrames > overlapFrames, let first = tail.first {
            let excess = tailFrames - overlapFrames
            tail[0] = Window(buffer: try Self.slice(first.buffer, offset: excess, count: first.frames - excess),
                             speech: first.speech)
            tailFrames = overlapFrames
        }
    }

    private func emit(overlapping: Bool) {
        guard let recording = current else { return }
        recording.finish()
        let segment = AudioSegment(recording: recording, startFrame: startFrame, endFrame: totalFrames,
                                   overlapFrames: currentOverlap, sampleRate: format.sampleRate)
        outstanding[recording.url] = recording
        if case .terminated = continuation.yield(segment) {
            outstanding.removeValue(forKey: recording.url)
            recording.discard()
        }
        prefix = overlapping ? tail : []
        tail = []
        tailFrames = 0
        current = nil
        currentFrames = 0
    }

    private static func slice(_ buffer: AVAudioPCMBuffer, offset: Int, count: Int) throws -> AVAudioPCMBuffer {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count)),
              let source = buffer.floatChannelData, let target = copy.floatChannelData else {
            throw LocalASRError.invalidInput("Cannot buffer recorded audio.")
        }
        copy.frameLength = AVAudioFrameCount(count)
        for channel in 0..<Int(buffer.format.channelCount) {
            target[channel].update(from: source[channel] + offset, count: count)
        }
        return copy
    }

    private static func energy(_ buffer: AVAudioPCMBuffer) throws -> Float {
        guard let channels = buffer.floatChannelData else {
            throw LocalASRError.invalidInput("Cannot read recorded audio samples.")
        }
        var sum: Double = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                let value = Double(channels[channel][frame])
                sum += value * value
            }
        }
        guard sum.isFinite else { throw LocalASRError.invalidInput("Audio contains non-finite samples.") }
        return Float(sqrt(sum / Double(buffer.frameLength) / Double(buffer.format.channelCount)))
    }
}
