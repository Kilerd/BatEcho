import XCTest
import MLX
@testable import voicer

private final class FakePipeline: ASRPipeline {
    var warm = false
    var calls = 0
    var beforeTranscribe: (() -> Void)?
    func warmUp(check: () throws -> Void) throws -> LocalASRResponse {
        XCTAssertFalse(Thread.isMainThread)
        try check()
        warm = true
        return LocalASRResponse(ready: true, modelLoadCount: 1)
    }
    func transcribe(audio: URL, options: ASROptions, check: () throws -> Void) throws -> LocalASRResponse {
        XCTAssertFalse(Thread.isMainThread)
        calls += 1
        beforeTranscribe?()
        try check()
        if audio.lastPathComponent == "mlx-error" {
            try Stream.withNewDefaultStream(device: .cpu) {
                _ = MLXArray.zeros([2, 3]) + MLXArray.zeros([4, 3])
                try check()
            }
        }
        if audio.lastPathComponent == "invalid" { throw LocalASRError.invalidInput("Invalid audio") }
        return LocalASRResponse(text: audio.lastPathComponent, ready: warm, modelLoadCount: calls)
    }
}

final class LocalASRClientTests: XCTestCase {
    func testWarmPipelineIsReusedAfterRequestError() async throws {
        let client = LocalASRClient(factory: { FakePipeline() })
        try await client.warmUp()
        do {
            _ = try await client.transcribe(audio: URL(fileURLWithPath: "/invalid"), hotwords: false)
            XCTFail("Expected request error")
        } catch LocalASRError.invalidInput { }
        let result = try await client.transcribe(audio: URL(fileURLWithPath: "/valid"), hotwords: true)
        XCTAssertEqual(result.text, "valid")
        XCTAssertEqual(result.ready, true)
        XCTAssertEqual(result.modelLoadCount, 2)
        await client.shutdown()
    }

    func testCancellationDiscardsOldResultAndNextRequestReusesPipeline() async throws {
        let started = expectation(description: "first inference started")
        let release = DispatchSemaphore(value: 0)
        let pipeline = FakePipeline()
        pipeline.beforeTranscribe = {
            if pipeline.calls == 1 { started.fulfill(); release.wait() }
        }
        let client = LocalASRClient(factory: { pipeline })
        let first = Task { try await client.transcribe(audio: URL(fileURLWithPath: "/old"), hotwords: false) }
        await fulfillment(of: [started], timeout: 3)
        first.cancel()
        release.signal()
        do { _ = try await first.value; XCTFail("Canceled inference escaped") }
        catch is CancellationError { }
        let next = try await client.transcribe(audio: URL(fileURLWithPath: "/new"), hotwords: false)
        XCTAssertEqual(next.text, "new")
        XCTAssertEqual(next.modelLoadCount, 2)
        await client.shutdown()
    }

    func testDeadlineRejectsResultAndShutdownReleasesPipeline() async throws {
        let client = LocalASRClient(timeout: 0, factory: { FakePipeline() })
        do { try await client.warmUp(); XCTFail("Expected timeout") }
        catch LocalASRError.timedOut { }
        await client.shutdown()
        let normal = LocalASRClient(factory: { FakePipeline() })
        try await normal.warmUp()
        await normal.shutdown()
        let result = try await normal.transcribe(audio: URL(fileURLWithPath: "/fresh"), hotwords: false)
        XCTAssertEqual(result.ready, false)
        XCTAssertEqual(result.modelLoadCount, 1)
        await normal.shutdown()
    }

    func testMissingAssetsFailWithoutLaunchingProcess() async throws {
        let client = LocalASRClient(runtime: LocalASRRuntime(directory: URL(fileURLWithPath: "/nonexistent-voicer-runtime")))
        do { try await client.warmUp(); XCTFail("Expected missing model") }
        catch LocalASRError.notPrepared { }
        await client.shutdown()
    }

    func testMLXErrorBecomesRequestErrorAndInvalidStateIsReleased() async throws {
        let client = LocalASRClient(factory: { FakePipeline() })
        try await client.warmUp()
        do {
            _ = try await client.transcribe(audio: URL(fileURLWithPath: "/mlx-error"), hotwords: false)
            XCTFail("Expected an MLX error")
        } catch is MLXError { }
        let result = try await client.transcribe(audio: URL(fileURLWithPath: "/fresh"), hotwords: false)
        XCTAssertEqual(result.ready, false)
        XCTAssertEqual(result.modelLoadCount, 1)
        await client.shutdown()
    }
}
