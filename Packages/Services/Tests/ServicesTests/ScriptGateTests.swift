import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("AppleScript concurrency gate")
struct ScriptGateTests {
    @Test("Concurrency limit clamps to one")
    func clampsLimit() async throws {
        let gate = ScriptGate(limit: 0)
        let holder = try await gate.acquire(
            scriptName: "holder",
            deadline: ContinuousClock().now.advanced(by: .seconds(1)),
            timeout: .seconds(1)
        )
        let queued = Task {
            try await gate.acquire(
                scriptName: "queued",
                deadline: ContinuousClock().now.advanced(by: .seconds(1)),
                timeout: .seconds(1)
            )
        }

        #expect(await awaitQueue(gate, count: 1))
        holder.release()
        let permit = try await queued.value
        permit.release()
    }

    @Test("Cancellation removes a queued waiter")
    func cancelsQueuedWaiter() async throws {
        let gate = ScriptGate(limit: 1)
        let holder = try await gate.acquire(
            scriptName: "holder",
            deadline: ContinuousClock().now.advanced(by: .seconds(1)),
            timeout: .seconds(1)
        )
        let queued = Task {
            try await gate.acquire(
                scriptName: "queued",
                deadline: ContinuousClock().now.advanced(by: .seconds(1)),
                timeout: .seconds(1)
            )
        }
        #expect(await awaitQueue(gate, count: 1))

        queued.cancel()
        let wasRemoved = await awaitQueue(gate, count: 0)
        holder.release()

        await #expect(throws: CancellationError.self) {
            _ = try await queued.value
        }
        #expect(wasRemoved)
    }

    @Test("Queued waiter expires before dispatch")
    func expiresQueuedWaiter() async throws {
        let gate = ScriptGate(limit: 1)
        let holder = try await gate.acquire(
            scriptName: "holder",
            deadline: ContinuousClock().now.advanced(by: .seconds(1)),
            timeout: .seconds(1)
        )
        let queued = Task {
            try await gate.acquire(
                scriptName: "queued",
                deadline: ContinuousClock().now.advanced(by: .milliseconds(30)),
                timeout: .milliseconds(30)
            )
        }
        #expect(await awaitQueue(gate, count: 1))
        let fallbackRelease = Task {
            try? await Task.sleep(for: .milliseconds(150))
            holder.release()
        }

        do {
            _ = try await queued.value
            Issue.record("Expected dispatch deadline")
        } catch let error as AppleScriptBridgeError {
            guard case let .dispatchDeadline(name, duration) = error else {
                Issue.record("Expected dispatchDeadline, got \(error)")
                await fallbackRelease.value
                return
            }
            #expect(name == "queued")
            #expect(duration == .milliseconds(30))
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }

        #expect(await awaitQueue(gate, count: 0))
        await fallbackRelease.value
    }

    @Test("Raising the limit resumes queued work")
    func raisesLimit() async throws {
        let gate = ScriptGate(limit: 1)
        let holder = try await gate.acquire(
            scriptName: "holder",
            deadline: ContinuousClock().now.advanced(by: .seconds(1)),
            timeout: .seconds(1)
        )
        let queued = Task {
            try await gate.acquire(
                scriptName: "queued",
                deadline: ContinuousClock().now.advanced(by: .seconds(1)),
                timeout: .seconds(1)
            )
        }
        #expect(await awaitQueue(gate, count: 1))

        await gate.updateLimit(2)

        let permit = try await queued.value
        permit.release()
        holder.release()
    }

    @Test("Queued permits are granted in FIFO order")
    func grantsFIFO() async throws {
        let gate = ScriptGate(limit: 1)
        let order = GateOrder()
        let holder = try await gate.acquire(
            scriptName: "holder",
            deadline: ContinuousClock().now.advanced(by: .seconds(1)),
            timeout: .seconds(1)
        )
        let first = Task {
            let permit = try await gate.acquire(
                scriptName: "first",
                deadline: ContinuousClock().now.advanced(by: .seconds(1)),
                timeout: .seconds(1)
            )
            await order.record(1)
            permit.release()
        }
        #expect(await awaitQueue(gate, count: 1))
        let second = Task {
            let permit = try await gate.acquire(
                scriptName: "second",
                deadline: ContinuousClock().now.advanced(by: .seconds(1)),
                timeout: .seconds(1)
            )
            await order.record(2)
            permit.release()
        }
        #expect(await awaitQueue(gate, count: 2))

        holder.release()
        try await first.value
        try await second.value

        #expect(await order.values == [1, 2])
    }

    @Test("Bridge configuration preserves active permits")
    func keepsBridgePermits() async throws {
        var configuration = AppleScriptConfig()
        configuration.concurrency = 2
        let installer = ScriptInstaller(
            scriptsDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("ScriptGate-\(UUID().uuidString)"),
            bundleScriptsDirectory: nil
        )
        let bridge = AppleScriptBridge(installer: installer, config: configuration)
        let first = try await bridge.acquirePermit(
            scriptName: "first",
            deadline: ContinuousClock().now.advanced(by: .seconds(1)),
            timeout: .seconds(1)
        )
        let second = try await bridge.acquirePermit(
            scriptName: "second",
            deadline: ContinuousClock().now.advanced(by: .seconds(1)),
            timeout: .seconds(1)
        )

        configuration.concurrency = 1
        await bridge.updateConfiguration(configuration)

        do {
            let permit = try await bridge.acquirePermit(
                scriptName: "queued",
                deadline: ContinuousClock().now.advanced(by: .milliseconds(30)),
                timeout: .milliseconds(30)
            )
            permit.release()
            Issue.record("Expected dispatch deadline")
        } catch let error as AppleScriptBridgeError {
            guard case .dispatchDeadline = error else {
                Issue.record("Expected dispatchDeadline, got \(error)")
                first.release()
                second.release()
                return
            }
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }
        first.release()
        second.release()
    }

    @Test("Permit releases capacity once")
    func releasesPermitOnce() async throws {
        let gate = ScriptGate(limit: 1)
        let first = try await gate.acquire(
            scriptName: "first",
            deadline: ContinuousClock().now.advanced(by: .seconds(1)),
            timeout: .seconds(1)
        )
        let secondTask = Task {
            try await gate.acquire(
                scriptName: "second",
                deadline: ContinuousClock().now.advanced(by: .seconds(1)),
                timeout: .seconds(1)
            )
        }
        #expect(await awaitQueue(gate, count: 1))

        first.release()
        first.release()
        let second = try await secondTask.value
        let thirdTask = Task {
            try await gate.acquire(
                scriptName: "third",
                deadline: ContinuousClock().now.advanced(by: .seconds(1)),
                timeout: .seconds(1)
            )
        }

        #expect(await awaitQueue(gate, count: 1))
        second.release()
        let third = try await thirdTask.value
        third.release()
    }
}

func awaitQueue(
    _ gate: ScriptGate,
    count: Int,
    timeout: Duration = .seconds(1)
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while await gate.queuedCount != count, clock.now < deadline {
        try? await clock.sleep(for: .milliseconds(1))
    }
    return await gate.queuedCount == count
}

private actor GateOrder {
    private(set) var values: [Int] = []

    func record(_ value: Int) {
        values.append(value)
    }
}
