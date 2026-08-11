import Testing
@testable import Services

@Suite("Test coordination helpers")
struct TestHelpersTests {
    @Test("Task wait times out without awaiting a stalled task")
    func taskWaitTimesOut() async {
        let entered = EventCounter()
        let stall = TaskStall(entered: entered)
        let task: Task<Int, any Error> = Task {
            await stall.wait()
            try Task.checkCancellation()
            return 1
        }
        #expect(await entered.wait(for: 1))

        await #expect(throws: TaskWaitTimeout.self) {
            _ = try await taskValue(task, timeout: .milliseconds(10))
        }
        #expect(task.isCancelled)

        await stall.release()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }
}

private actor TaskStall {
    private let entered: EventCounter
    private var continuation: CheckedContinuation<Void, Never>?

    init(entered: EventCounter) {
        self.entered = entered
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.record()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
