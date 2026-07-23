import Foundation
import Testing
@testable import Services

@Suite("Single dispatch safety")
struct SingleDispatchTests {
    @Test("Pre-dispatch deadline does not record an attempt")
    func deadlineIsUnattempted() async {
        let bridge = makeBridge()
        let attempts = AttemptCounter()

        do {
            _ = try await bridge.updateTrackProperty(
                trackID: "101",
                property: "genre",
                value: "Metal",
                onAttempt: { await attempts.record() },
                execute: {
                    throw AppleScriptBridgeError.dispatchDeadline(
                        scriptName: "update_property",
                        duration: .seconds(1)
                    )
                }
            )
            Issue.record("Expected dispatchDeadline")
        } catch let error as AppleScriptBridgeError {
            guard case .dispatchDeadline = error else {
                Issue.record("Expected dispatchDeadline, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }
        #expect(await attempts.value == 0)
    }

    @Test("Pre-dispatch cancellation does not record an attempt")
    func cancellationIsUnattempted() async {
        let bridge = makeBridge()
        let attempts = AttemptCounter()

        await #expect(throws: CancellationError.self) {
            _ = try await bridge.updateTrackProperty(
                trackID: "101",
                property: "genre",
                value: "Metal",
                onAttempt: { await attempts.record() },
                execute: { throw CancellationError() }
            )
        }
        #expect(await attempts.value == 0)
    }

    @Test("Unknown dispatched outcome records an attempt")
    func outcomeIsAttempted() async {
        let bridge = makeBridge()
        let attempts = AttemptCounter()

        await #expect(throws: AppleScriptOutcomeError.self) {
            _ = try await bridge.updateTrackProperty(
                trackID: "101",
                property: "genre",
                value: "Metal",
                onAttempt: { await attempts.record() },
                execute: {
                    throw AppleScriptOutcomeError(scriptName: "update_property", duration: .seconds(1))
                }
            )
        }
        #expect(await attempts.value == 1)
    }

    @Test("unknown outcome preserves a typed checkpoint store failure")
    func storeFailureKeepsOutcome() async throws {
        let bridge = makeBridge()
        let input = writeInput()
        let itemID = try #require(input.workItems.first?.id)
        let request = RunRequest.manualWrite(input: input)
        let durable = RunLifecycleSnapshot(
            request: request,
            scope: input.scope,
            startedAt: Date(timeIntervalSince1970: 100),
            phase: .active(.writing)
        )
        let checkpoint = WorkCheckpoint.beforeAttempt([itemID])
        let candidate = try durable.applying(checkpoint)
        let stored = CheckpointStoreFailure(
            checkpoint: checkpoint,
            candidate: candidate,
            durableSnapshot: durable,
            isWriteAdjacent: true,
            reason: "checkpoint store unavailable"
        )

        do {
            _ = try await bridge.updateTrackProperty(
                trackID: "101",
                property: "genre",
                value: "Metal",
                onAttempt: { throw WorkCheckpointError.store(stored) },
                execute: {
                    throw AppleScriptOutcomeError(
                        scriptName: "update_property",
                        reason: "connection ended before reply"
                    )
                }
            )
            Issue.record("Expected typed checkpoint store failure")
        } catch let WorkCheckpointError.store(failure) {
            #expect(failure.checkpoint == checkpoint)
            #expect(failure.candidate == candidate)
            #expect(failure.durableSnapshot == durable)
            #expect(failure.isWriteAdjacent)
            #expect(failure.reason.contains("checkpoint store unavailable"))
            #expect(failure.reason.contains("connection ended before reply"))
            #expect(failure.reason.contains("outcome is unknown"))
        } catch {
            Issue.record("Expected typed checkpoint store failure, got \(error)")
        }
    }

    @Test("Successful response records an attempt")
    func successIsAttempted() async throws {
        let bridge = makeBridge()
        let attempts = AttemptCounter()

        let result = try await bridge.updateTrackProperty(
            trackID: "101",
            property: "genre",
            value: "Metal",
            onAttempt: { await attempts.record() },
            execute: { "Success: Updated track 101" }
        )

        #expect(result == .changed)
        #expect(await attempts.value == 1)
    }

    @Test("Invalid response still records an attempt")
    func invalidResponseIsAttempted() async {
        let bridge = makeBridge()
        let attempts = AttemptCounter()

        await #expect(throws: AppleScriptOutcomeError.self) {
            _ = try await bridge.updateTrackProperty(
                trackID: "101",
                property: "genre",
                value: "Metal",
                onAttempt: { await attempts.record() },
                execute: { "Updated track 101" }
            )
        }
        #expect(await attempts.value == 1)
    }

    private func makeBridge() -> AppleScriptBridge {
        AppleScriptBridge(installer: ScriptInstaller(
            scriptsDirectory: FileManager.default.temporaryDirectory,
            bundleScriptsDirectory: nil
        ))
    }
}

private actor AttemptCounter {
    private(set) var value = 0

    func record() {
        value += 1
    }
}
