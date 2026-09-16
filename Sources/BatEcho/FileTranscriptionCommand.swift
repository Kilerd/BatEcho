import Foundation

/// Exercises the same native MLX pipeline as Fn dictation without microphone or
/// Accessibility permissions. Repeated --transcribe-file flags reuse one model.
enum FileTranscriptionCommand {
    static func runIfRequested(_ arguments: [String]) -> Bool {
        if arguments == ["--verify-runtime"] {
            do {
                try RuntimeValidation.checkCPUVAD()
                print("BatEcho CPU VAD runtime check passed.")
                return true
            } catch { fail(error.localizedDescription) }
        }
        if arguments == ["--prepare-model"] {
            Task {
                do {
                    try await LocalASRRuntime().prepare { message in
                        FileHandle.standardError.write(Data((message + "\n").utf8))
                    }
                    exit(0)
                } catch { fail(error.localizedDescription) }
            }
            RunLoop.main.run()
            return true
        }
        guard arguments.contains("--transcribe-file") else { return false }
        var files: [URL] = []
        var hotwords = true
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
            case "--no-hotwords": hotwords = false
            case "--no-correction": correction = false
            default: fail("Unknown argument: \(arguments[index])")
            }
            index += 1
        }
        let client = LocalASRClient()
        Task {
            do {
                for file in files {
                    try await transcribeAndWrite(file, client: client,
                        options: ASROptions(hotwords: hotwords, correction: correction))
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

    // Keep each response in its own async frame. In optimized Swift builds,
    // retaining this large value in the batch task can corrupt frame teardown
    // when the task subsequently awaits shutdown.
    @inline(never)
    private static func transcribeAndWrite(_ file: URL, client: LocalASRClient, options: ASROptions) async throws {
        let result = try await ContinuousTranscription.transcribeFile(file, client: client, options: options)
        var data = try JSONEncoder().encode(result)
        data.append(0x0A)
        try FileHandle.standardOutput.write(contentsOf: data)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
