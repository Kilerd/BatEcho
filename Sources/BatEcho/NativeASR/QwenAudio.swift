import Foundation
import MLX
import MLXFFT

/// Qwen's WhisperFeatureExtractor recipe: 16 kHz, periodic Hann, Slaney mel
/// filters, reflection padding and the final STFT frame removed.
enum QwenAudio {
    private static let window = (0..<400).map {
        Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / 400))
    }
    private static let filters: [Float] = {
        func mel(_ hz: Double) -> Double {
            hz < 1000 ? hz / (200.0 / 3) : 15 + log(hz / 1000) / (log(6.4) / 27)
        }
        func hz(_ mel: Double) -> Double {
            mel < 15 ? mel * (200.0 / 3) : 1000 * exp((mel - 15) * log(6.4) / 27)
        }
        let points = (0..<130).map { hz(Double($0) * mel(8000) / 129) }
        return (0..<201).flatMap { frequency in
            (0..<128).map { bin in
                let value = Double(frequency) * 40
                let triangle = max(0, min((value - points[bin]) / (points[bin + 1] - points[bin]),
                                          (points[bin + 2] - value) / (points[bin + 2] - points[bin + 1])))
                return Float(triangle * 2 / (points[bin + 2] - points[bin]))
            }
        }
    }()

    /// Returns [time, 128], with no 30-second padding or truncation.
    static func features(_ samples: [Float]) -> MLXArray {
        let wave = samples + Array(repeating: Float(0), count: max(0, 8000 - samples.count))
        let reflected = Array(wave[1...200].reversed()) + wave + Array(wave[(wave.count - 201)..<(wave.count - 1)].reversed())
        let count = wave.count / 160
        let frames = asStrided(MLXArray(reflected), [count, 400], strides: [160, 1]) * MLXArray(window)
        let power = abs(MLXFFT.rfft(frames, axis: 1)).square()
        let mel = power.matmul(MLXArray(filters, [201, 128]))
        let logs = log10(maximum(mel, Float(1e-10)))
        return (maximum(logs, max(logs) - 8) + 4) / 4
    }
}
