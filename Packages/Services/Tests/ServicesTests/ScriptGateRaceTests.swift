import Testing
@testable import Services

#if DEBUG
@Suite("Script gate grant races")
struct ScriptGateRaceTests {
    @Test("Expired grant returns its permit")
    func releasesExpiredGrant() async throws {
        let pause = GrantPause(grant: 2)
        let gate = ScriptGate(
            limit: 1,
            hooks: .init(afterGrant: { await pause.enter() })
        )
        let holder = try await gate.acquire(
            scriptName: "holder",
            deadline: ContinuousClock().now.advanced(by: .seconds(30)),
            timeout: .seconds(30)
        )
        let expired = Task {
            let deadline = ContinuousClock().now.advanced(by: .seconds(1))
            return try await gate.acquire(
                scriptName: "expired",
                deadline: deadline,
                timeout: .seconds(1)
            )
        }
        #expect(await awaitQueue(gate, count: 1))
        let next = Task {
            try await gate.acquire(
                scriptName: "next",
                deadline: ContinuousClock().now.advanced(by: .seconds(30)),
                timeout: .seconds(30)
            )
        }
        #expect(await awaitQueue(gate, count: 2))

        holder.release()
        #expect(await pause.waitForEntry())
        try await Task.sleep(for: .milliseconds(1100))
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
