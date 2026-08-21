import Foundation
import Testing
@testable import Services

#if DEBUG
@Suite("ProviderAdmission — permit state")
struct ProviderAdmissionStateTests {
    @Test("Queued operations start in arrival order")
    func queuedOperationsAreFIFO() async throws {
        let enqueueProbe = AdmissionEnqueueProbe()
        let order = AdmissionOrderProbe()
        let firstGate = AdmissionOperationGate()
        let admission = ProviderAdmission(
            limit: 1,
            hooks: (didEnqueue: { enqueueProbe.record() }, afterGrant: nil)
        )

        let first = operationTask(admission, name: "first", order: order, gate: firstGate)
        #expect(await order.waitForCount(1))
        let second = operationTask(admission, name: "second", order: order)
        #expect(await enqueueProbe.waitForCount(1))
        let third = operationTask(admission, name: "third", order: order)
        #expect(await enqueueProbe.waitForCount(2))

        await firstGate.open()
        try await awaitOperations([first, second, third])

        #expect(await order.names == ["first", "second", "third"])
    }

    @Test("Cancellation after grant skips the operation and advances the queue")
    func cancelledGrantAdvancesQueue() async throws {
        let enqueueProbe = AdmissionEnqueueProbe()
        let grantBarrier = AdmissionGrantBarrier(blockingGrant: 2)
        let order = AdmissionOrderProbe()
        let firstGate = AdmissionOperationGate()
        let admission = ProviderAdmission(
            limit: 1,
            hooks: (
                didEnqueue: { enqueueProbe.record() },
                afterGrant: { await grantBarrier.reach() }
            )
        )

        let first = operationTask(admission, name: "first", order: order, gate: firstGate)
        #expect(await order.waitForCount(1))
        let cancelled = operationTask(admission, name: "cancelled", order: order)
        #expect(await enqueueProbe.waitForCount(1))
        let third = operationTask(admission, name: "third", order: order)
        #expect(await enqueueProbe.waitForCount(2))

        await firstGate.open()
        #expect(await grantBarrier.waitUntilBlocked())
        cancelled.cancel()
        await grantBarrier.release()

        await #expect(throws: CancellationError.self) {
            _ = try await taskValue(cancelled, timeout: .milliseconds(200))
        }
        try await awaitOperations([first, third])
        #expect(await order.names == ["first", "third"])
    }

    private func operationTask(
        _ admission: ProviderAdmission,
        name: String,
        order: AdmissionOrderProbe,
        gate: AdmissionOperationGate? = nil
    ) -> Task<Void, any Error> {
        Task {
            try await admission.execute(timeout: .seconds(2)) {
                await order.record(name)
                await gate?.wait()
            }
        }
    }

    private func awaitOperations(_ tasks: [Task<Void, any Error>]) async throws {
        for task in tasks {
            _ = try await taskValue(task, timeout: .seconds(1))
        }
    }
}

private final class AdmissionEnqueueProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.withLock {
            count += 1
        }
    }

    func waitForCount(_ expectedCount: Int) async -> Bool {
        let deadline = ContinuousClock().now.advanced(by: .seconds(1))
        while currentCount < expectedCount, ContinuousClock().now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return currentCount >= expectedCount
    }

    private var currentCount: Int {
        lock.withLock { count }
    }
}

private actor AdmissionGrantBarrier {
    private let blockingGrant: Int
    private var grantCount = 0
    private var isBlocked = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(blockingGrant: Int) {
        self.blockingGrant = blockingGrant
    }

    func reach() async {
        grantCount += 1
        guard grantCount == blockingGrant else { return }
        isBlocked = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilBlocked() async -> Bool {
        let deadline = ContinuousClock().now.advanced(by: .seconds(1))
        while !isBlocked, ContinuousClock().now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return isBlocked
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor AdmissionOperationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor AdmissionOrderProbe {
    private(set) var names: [String] = []

    func record(_ name: String) {
        names.append(name)
    }

    func waitForCount(_ expectedCount: Int) async -> Bool {
        let deadline = ContinuousClock().now.advanced(by: .seconds(1))
        while names.count < expectedCount, ContinuousClock().now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return names.count >= expectedCount
    }
}
#endif
