import Testing
@testable import Services

@Suite("AppleScript execution deadline")
struct ScriptDeadlineTests {
    @Test("Expired budget fails before execution")
    func rejectsExpiredBudget() async {
        do {
            _ = try await AppleScriptBridge.executeBeforeDeadline(
                deadline: ContinuousClock().now.advanced(by: .milliseconds(-1)),
                scriptName: "expired",
                timeout: .seconds(1)
            ) {
                "unexpected"
            }
            Issue.record("Expected dispatch deadline")
        } catch let error as AppleScriptBridgeError {
            guard case .dispatchDeadline = error else {
                Issue.record("Expected dispatchDeadline, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }
    }

    @Test("Fast execution returns its value")
    func returnsFastValue() async throws {
        let result = try await AppleScriptBridge.executeBeforeDeadline(
            deadline: ContinuousClock().now.advanced(by: .seconds(1)),
            scriptName: "fast",
            timeout: .seconds(1)
        ) {
            "ok"
        }

        #expect(result == "ok")
    }

    @Test("Execution uses the remaining admission budget")
    func usesRemainingBudget() async throws {
        let clock = ContinuousClock()
        let timeout: Duration = .seconds(2)
        let deadline = clock.now.advanced(by: timeout)
        try await clock.sleep(for: .seconds(1))

        do {
            _ = try await AppleScriptBridge.executeBeforeDeadline(
                deadline: deadline,
                scriptName: "delayed",
                timeout: timeout
            ) {
                try await Task.sleep(for: .milliseconds(1500))
                return "late"
            }
            Issue.record("Expected the original deadline to expire")
        } catch let error as AppleScriptBridgeError {
            guard case let .timeout(name, duration) = error else {
                Issue.record("Expected timeout, got \(error)")
                return
            }
            #expect(name == "delayed")
            #expect(duration == timeout)
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }
    }
}
