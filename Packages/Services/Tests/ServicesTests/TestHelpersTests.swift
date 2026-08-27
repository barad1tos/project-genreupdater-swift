import Core
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

    @Test("Mirror revision exhaustion leaves the in-memory store unchanged")
    func mirrorRevisionExhaustionIsAtomic() async throws {
        let store = MockTrackStore(revision: MirrorRevision(value: .max))
        let update = try MirrorCommit(
            baseRevision: MirrorRevision(value: .max),
            membershipChange: replacementMembership(for: [
                Track(id: "new-track", name: "New", artist: "Artist", album: "Album", appleScriptID: "new-track"),
            ]),
            repairs: [],
            upserts: [Track(
                id: "new-track",
                name: "New",
                artist: "Artist",
                album: "Album",
                appleScriptID: "new-track"
            )],
            certificates: .invalidate(.membershipChanged)
        )
        let before = try await store.loadMirrorSnapshot()

        do {
            _ = try await store.commitMirror(update)
            Issue.record("A mirror commit must fail when its revision is exhausted")
        } catch {
            #expect(error.localizedDescription == "Mirror revision exhausted at \(UInt64.max).")
        }

        let after = try await store.loadMirrorSnapshot()
        #expect(after == before)
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
