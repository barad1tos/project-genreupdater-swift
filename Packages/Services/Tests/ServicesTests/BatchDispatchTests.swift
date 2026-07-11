import Core
import Foundation
import Testing
@testable import Services

@Suite("Batch dispatch safety")
struct BatchDispatchTests {
    @Test("Pre-dispatch batch failure reaches the caller")
    func keepsDeadline() async throws {
        let fixture = try makeBatchBridge()
        let bridge = fixture.bridge
        let scriptsDirectory = fixture.directory
        defer { try? FileManager.default.removeItem(at: scriptsDirectory) }
        let attempts = BatchAttemptCounter()

        do {
            try await bridge.batchUpdateTracks([
                (trackID: "101", property: "genre", value: "Metal")
            ]) { _ in
                _ = await attempts.next()
                throw AppleScriptBridgeError.dispatchDeadline(
                    scriptName: "batch_update_tracks",
                    duration: .seconds(1)
                )
            }
            Issue.record("Expected dispatchDeadline")
        } catch let error as AppleScriptBridgeError {
            guard case .dispatchDeadline = error else {
                Issue.record("Expected dispatchDeadline, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }
        #expect(await attempts.value == 1)
    }

    @Test("Ambiguous batch failure requires verification")
    func wrapsAmbiguousFailure() async throws {
        let fixture = try makeBatchBridge()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        do {
            try await fixture.bridge.batchUpdateTracks([
                (trackID: "101", property: "genre", value: "Metal")
            ]) { _ in
                throw AppleScriptBridgeError.timeout(
                    scriptName: "batch_update_tracks",
                    duration: .seconds(1)
                )
            }
            Issue.record("Expected batch verification failure")
        } catch let error as AppleScriptBatchVerificationError {
            #expect(error.updateCount == 1)
        } catch {
            Issue.record("Expected AppleScriptBatchVerificationError, got \(error)")
        }
    }

    @Test("Unknown batch outcome reaches the caller")
    func preservesUnknownOutcome() async throws {
        let fixture = try makeBatchBridge()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        await #expect(throws: AppleScriptOutcomeError.self) {
            try await fixture.bridge.batchUpdateTracks([
                (trackID: "101", property: "genre", value: "Metal")
            ]) { _ in
                throw AppleScriptOutcomeError(scriptName: "batch_update_tracks", duration: .seconds(3))
            }
        }
    }

    private func makeBridge(scriptsDirectory: URL = FileManager.default.temporaryDirectory) -> AppleScriptBridge {
        let installer = ScriptInstaller(
            scriptsDirectory: scriptsDirectory,
            bundleScriptsDirectory: nil
        )
        return AppleScriptBridge(installer: installer)
    }

    private func makeBatchBridge() throws -> (bridge: AppleScriptBridge, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatchDispatchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("batch_update_tracks.scpt"))
        return (makeBridge(scriptsDirectory: directory), directory)
    }
}

private actor BatchAttemptCounter {
    private var count = 0

    var value: Int {
        count
    }

    func next() -> Int {
        count += 1
        return count
    }
}
