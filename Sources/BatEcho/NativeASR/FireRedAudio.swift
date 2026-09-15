// SPDX-License-Identifier: MIT
// Feature recipe ported from mlx-audio 0.5.4, dsp.compute_fbank_kaldi.
// Copyright (c) 2025 Prince Canuma. See ASRResources/ThirdPartyNotices.txt.
import Foundation
import MLX
import MLXFFT

/// Keep the Python reference's feature recipe exactly: snip edges, no dither,
/// Hamming window, mel-domain triangles and unchanged first preemphasis sample.
/// The upstream Swift generic mel filter differs from this trained recipe.
enum FireRedASR2Audio {
    static func extractFbank(_ audio: MLXArray) -> MLXArray {
        let waveform = audio.reshaped([-1]).asType(.float32) * Float(32768)
        let count = waveform.size
        guard count >= 400 else { return MLXArray.zeros([0, 80]) }
        let framesCount = 1 + (count - 400) / 160
        var frames = asStrided(waveform, [framesCount, 400], strides: [160, 1])
        frames = frames - mean(frames, axis: 1, keepDims: true)
        frames = concatenated([
            frames[0..., 0..<1],
            frames[0..., 1..<400] - Float(0.97) * frames[0..., 0..<399]
        ], axis: 1)
        let n = MLXArray(0..<400).asType(.float32)
        let window = Float(0.54) - Float(0.46) * cos(2 * Float.pi * n / 399)
        frames = concatenated([frames * window, MLXArray.zeros([framesCount, 112])], axis: 1)
        let spectrum = abs(MLXFFT.rfft(frames, axis: 1)).square()

        func mel(_ x: MLXArray) -> MLXArray { 1127 * log(1 + x / 700) }
        let low: Float = mel(MLXArray(Float(20))).item()
        let high: Float = mel(MLXArray(Float(8000))).item()
        let delta = (high - low) / 81
        let bins = MLXArray(0..<80).asType(.float32).reshaped([80, 1])
        let left = low + bins * delta
        let center = low + (bins + 1) * delta
        let right = low + (bins + 2) * delta
        let frequencies = mel(Float(31.25) * MLXArray(0..<256).asType(.float32)).reshaped([1, 256])
        let filters = maximum(0, minimum((frequencies - left) / (center - left),
                                        (right - frequencies) / (right - center)))
        let paddedFilters = concatenated([filters, MLXArray.zeros([80, 1])], axis: 1)
        return log(maximum(spectrum.matmul(paddedFilters.T), Float(1e-8)))
    }

    static func applyCMVN(_ features: MLXArray, means: MLXArray, istd: MLXArray) -> MLXArray {
        (features - means) * istd
    }
}

public struct FireRedOutput {
    let text: String
    let tokens: [Int]
    let confidence: Float
    let truncated: Bool
}
