import Foundation
import XCTest
@testable import voicer

final class LocalASRClientTests: XCTestCase {
    private func client(timeout: Double = 3) throws -> (LocalASRClient, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = Bundle.module.url(forResource: "worker", withExtension: "py", subdirectory: "Fixtures")!
        let client = LocalASRClient(configuration: .init(
            executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", fixture.path],
            workingDirectory: directory, timeoutSeconds: timeout))
        addTeardownBlock {
            await client.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
        return (client, directory)
    }

    private func transcribe(_ name: String, client: LocalASRClient) async throws -> LocalASRResponse {
        try await client.transcribe(audio: URL(fileURLWithPath: "/\(name)"), hotwords: true)
    }

    func testWarmWorkerIsReusedAndSplitUTF8IsDecoded() async throws {
        let (client, _) = try client()
        try await client.warmUp()
        let first = try await transcribe("chunked", client: client)
        let second = try await transcribe("normal", client: client)
        XCTAssertEqual(first.text, "你好 Kubernetes")
        XCTAssertEqual(first.model, second.model)
        XCTAssertEqual(second.modelLoadCount, 1)
    }

    func testPerRequestErrorDoesNotKillWorker() async throws {
        let (client, _) = try client()
        let first = try await transcribe("normal", client: client)
        do {
            _ = try await transcribe("error", client: client)
            XCTFail("Expected the worker's vocabulary error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Invalid vocabulary")
        }
        let second = try await transcribe("normal", client: client)
        XCTAssertEqual(first.model, second.model)
    }

    func testCrashFailsRequestAndNextRequestRestartsWorker() async throws {
        let (client, _) = try client()
        do {
            _ = try await transcribe("crash", client: client)
            XCTFail("Expected a disconnected worker")
        } catch {
            guard case LocalASRError.disconnected = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let result = try await transcribe("normal", client: client)
        XCTAssertEqual(result.text, "你好 Kubernetes")
    }

    func testInvalidWireDataFailsWithoutHanging() async throws {
        let (client, _) = try client()
        do {
            _ = try await transcribe("invalid", client: client)
            XCTFail("Expected invalid response")
        } catch {
            guard case LocalASRError.invalidResponse = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testTimeoutStopsAnUnresponsiveWorker() async throws {
        let (client, _) = try client(timeout: 0.25)
        do {
            _ = try await transcribe("hang", client: client)
            XCTFail("Expected timeout")
        } catch {
            guard case LocalASRError.timedOut = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testCancellationDiscardsOldWorkerAndLateResults() async throws {
        let (client, directory) = try client()
        let old = Task { try await self.transcribe("hang", client: client) }
        let started = directory.appendingPathComponent("started")
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: started.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        let oldPID = try String(contentsOf: started)
        old.cancel()
        do {
            _ = try await old.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        let next = try await transcribe("normal", client: client)
        XCTAssertNotEqual(next.model, oldPID)
        XCTAssertEqual(next.text, "你好 Kubernetes")
    }

    func testMissingRuntimeProducesActionableError() async throws {
        let client = LocalASRClient(configuration: .init(executable: URL(fileURLWithPath: "/missing/python"),
            arguments: [], workingDirectory: FileManager.default.temporaryDirectory))
        do {
            try await client.warmUp()
            XCTFail("Expected setup error")
        } catch {
            guard case LocalASRError.notPrepared = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }
}
