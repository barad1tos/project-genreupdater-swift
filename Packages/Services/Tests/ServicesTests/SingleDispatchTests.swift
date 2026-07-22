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
