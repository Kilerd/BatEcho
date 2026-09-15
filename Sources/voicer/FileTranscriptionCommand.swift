import Foundation

/// Exercises the same persistent bridge as Fn dictation without microphone or
/// Accessibility permissions. Repeated --transcribe-file flags reuse one model.
enum FileTranscriptionCommand {
    static func runIfRequested(_ arguments: [String]) -> Bool {
        guard arguments.contains("--transcribe-file") else { return false }
        var files: [URL] = []
        var hotwords = false
        var correction = true
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--transcribe-file":
                index += 1
                guard index < arguments.count else {
                    fail("--transcribe-file requires an audio path")
                }
                files.append(URL(fileURLWithPath: arguments[index]))
            case "--hotwords": hotwords = true
            case "--no-correction": correction = false
            default: fail("Unknown argument: \(arguments[index])")
            }
            index += 1
        }
        let client = LocalASRClient()
        Task {
            do {
                for file in files {
                    let result = try await client.transcribe(audio: file, hotwords: hotwords, correction: correction)
                    var data = try JSONEncoder().encode(result)
                    data.append(0x0A)
                    try FileHandle.standardOutput.write(contentsOf: data)
                }
                await client.shutdown()
                exit(0)
            } catch {
                await client.shutdown()
                fail(error.localizedDescription)
            }
        }
        RunLoop.main.run()
        return true
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
