import AVFoundation

enum NativeAudio {
    static let maximumSegmentDuration: TimeInterval = 30

    static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard (8000...192000).contains(format.sampleRate), (1...8).contains(format.channelCount) else {
            throw LocalASRError.invalidInput("Unsupported audio format.")
        }
        guard Double(file.length) / format.sampleRate <= maximumSegmentDuration + 0.001 else {
            throw LocalASRError.invalidInput("An audio segment is too long to recognize.")
        }
        guard file.length > 0 else { return [] }
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw LocalASRError.invalidInput("Cannot read audio.")
        }
        var samples: [Float] = []
        samples.reserveCapacity(Int(file.length))
        // A read may return fewer frames than requested, even for PCM CAF files.
        // Drain the remaining frames so a partial final buffer keeps its tail.
        while file.framePosition < file.length {
            try file.read(into: input, frameCount: AVAudioFrameCount(min(4096, file.length - file.framePosition)))
            guard input.frameLength > 0, let channels = input.floatChannelData else {
                throw LocalASRError.invalidInput("Cannot read remaining audio samples.")
            }
            for frame in 0..<Int(input.frameLength) {
                var sample: Float = 0
                for channel in 0..<Int(format.channelCount) {
                    sample += channels[channel][frame] / Float(format.channelCount)
                }
                samples.append(sample)
            }
        }
        let count = samples.count
        guard samples.allSatisfy(\.isFinite) else { throw LocalASRError.invalidInput("Audio contains non-finite samples.") }
        guard format.sampleRate != 16000 else { return samples }
        let monoFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)!
        let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(count))!
        mono.frameLength = AVAudioFrameCount(count)
        mono.floatChannelData![0].update(from: samples, count: count)
        let destination = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        guard let converter = AVAudioConverter(from: monoFormat, to: destination) else {
            throw LocalASRError.invalidInput("Cannot convert this audio sample rate.")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let output = AVAudioPCMBuffer(pcmFormat: destination, frameCapacity: AVAudioFrameCount(ceil(Double(count) * 16000 / format.sampleRate)) + 512)!
        var supplied = false
        var error: NSError?
        var result: [Float] = []
        while true {
            let status = converter.convert(to: output, error: &error) { _, state in
                if supplied { state.pointee = .endOfStream; return nil }
                supplied = true
                state.pointee = .haveData
                return mono
            }
            if let error { throw error }
            guard status != .error else { throw LocalASRError.invalidInput("Audio conversion failed.") }
            result += Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            if status == .endOfStream { break }
            guard output.frameLength > 0 else { throw LocalASRError.invalidInput("Audio conversion stalled.") }
        }
        guard result.allSatisfy(\.isFinite), result.count <= Int(maximumSegmentDuration * 16000) + 16 else {
            throw LocalASRError.invalidInput("Invalid converted audio.")
        }
        return result
    }
}
