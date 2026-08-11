import Foundation
import Testing
@testable import Services

#if DEBUG
@Suite("Script gate grant races")
struct ScriptGateRaceTests {
    @Test("Expired grant returns its permit")
    func releasesExpiredGrant() async throws {
        let clock = GrantClock()
        let expiredDeadline = clock.now.advanced(by: .seconds(60))
        let nextDeadline = clock.now.advanced(by: .seconds(120))
        let pause = GrantPause(grant: 2)
        let gate = ScriptGate(
            limit: 1,
            hooks: .init(
                afterGrant: { await pause.enter() },
                now: { clock.now }
            )
        )
        let holder = try await gate.acquire(
            scriptName: "holder",
            deadline: nextDeadline,
            timeout: .seconds(120)
        )
        let expired = Task {
            try await gate.acquire(
                scriptName: "expired",
                deadline: expiredDeadline,
                timeout: .seconds(60)
            )
        }
        #expect(await awaitQueue(gate, count: 1))
        let next = Task {
            try await gate.acquire(
                scriptName: "next",
                deadline: nextDeadline,
                timeout: .seconds(120)
            )
        }
        #expect(await awaitQueue(gate, count: 2))

        holder.release()
        #expect(await pause.waitForEntry())
        clock.advance(past: expiredDeadline)
        await pause.open()

        var didExpire = false
        do {
            _ = try await expired.value
            Issue.record("Expected dispatch deadline")
        } catch let error as AppleScriptBridgeError {
            if case .dispatchDeadline = error {
                didExpire = true
            } else {
                Issue.record("Expected dispatchDeadline, got \(error)")
            }
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }
        #expect(didExpire)
        let permit = try await next.value
        permit.release()
    }
}

// Safety: the lock protects the test clock instant and every access to it.
private final class GrantClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock().now

    var now: ContinuousClock.Instant {
        lock.withLock { instant }
    }

    func advance(past deadline: ContinuousClock.Instant) {
        lock.withLock { instant = deadline.advanced(by: .nanoseconds(1)) }
    }
}

private actor GrantPause {
    private let targetGrant: Int
    private var grantCount = 0
    private var isWaiting = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(grant: Int) {
        targetGrant = grant
    }

    func enter() async {
        grantCount += 1
        guard grantCount == targetGrant else { return }
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitForEntry(timeout: Duration = .seconds(30)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !isWaiting, clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(1))
        }
        return isWaiting
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}
#endif
