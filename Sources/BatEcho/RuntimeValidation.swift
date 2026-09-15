import Foundation
import MLX

/// Runs inside the signed app to catch CPU JIT / library-validation failures.
/// Random model parameters exercise the real VAD operations without downloading
/// weights, accessing the microphone, or claiming recognition accuracy.
enum RuntimeValidation {
    static func checkCPUVAD() throws {
        try MLX.withError { error in
            try Stream.withNewDefaultStream(device: .cpu) {
                let detector = SileroVAD(SileroVADConfig())
                var state = try detector.initialState()
                for _ in 0..<2 {
                    let (probability, next) = try detector.feed(
                        chunk: MLXArray.zeros([512]), state: state)
                    eval(probability, next.context, next.lstmState!)
                    try error.check()
                    let value = probability.item(Float.self)
                    guard value.isFinite, (0...1).contains(value) else {
                        throw LocalASRError.invalidInput("CPU VAD produced an invalid probability.")
                    }
                    state = next
                }
            }
        }
    }
}
