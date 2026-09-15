import AVFoundation

enum NativeAudio {
    static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard (8000...192000).contains(format.sampleRate), (1...8).contains(format.channelCount) else {
            throw LocalASRError.invalidInput("Unsupported audio format.")
        }
        guard Double(file.length) / format.sampleRate <= 30.001 else {
            throw LocalASRError.invalidInput("Please dictate no more than 30 seconds at a time.")
        }
        guard file.length > 0 else { return [] }
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw LocalASRError.invalidInput("Cannot read audio.")
        }
        try file.read(into: input)
        let count = Int(input.frameLength)
        var samples = [Float](repeating: 0, count: count)
        guard let channels = input.floatChannelData else { throw LocalASRError.invalidInput("Cannot read audio samples.") }
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<count { samples[frame] += channels[channel][frame] / Float(format.channelCount) }
        }
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
        guard result.allSatisfy(\.isFinite), result.count <= 480016 else {
            throw LocalASRError.invalidInput("Invalid converted audio.")
        }
        return result
    }
}
