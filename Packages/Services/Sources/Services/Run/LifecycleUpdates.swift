import Foundation

/// A bounded lifecycle sequence that coalesces superseded progress while retaining
/// the newest state for consumer resynchronization. The sequence is single-pass:
/// additional iterators finish immediately without closing the active subscription.
public struct LifecycleUpdates: AsyncSequence, Sendable {
    public typealias Element = RunLifecycleSnapshot

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let buffer: LifecycleUpdateBuffer
        private let lease: LifecycleLease?

        fileprivate init(buffer: LifecycleUpdateBuffer, lease: LifecycleLease?) {
            self.buffer = buffer
            self.lease = lease
        }

        public mutating func next() async -> RunLifecycleSnapshot? {
            guard let lease else { return nil }
            _ = lease
            return await buffer.next()
        }
    }

    private let buffer: LifecycleUpdateBuffer
    private let lease: LifecycleLease

    init(buffer: LifecycleUpdateBuffer) {
        self.buffer = buffer
        lease = LifecycleLease(buffer: buffer)
    }

    public static var finished: Self {
        let buffer = LifecycleUpdateBuffer(limit: 1)
        buffer.finish()
        return Self(buffer: buffer)
    }

    public func makeAsyncIterator() -> AsyncIterator {
        let activeLease = buffer.claimIterator() ? lease : nil
        return AsyncIterator(buffer: buffer, lease: activeLease)
    }
}

final class LifecycleUpdateBuffer: @unchecked Sendable {
    private enum Delivery {
        case snapshot(RunLifecycleSnapshot)
        case finished
        case waiting
    }

    private let limit: Int
    private let lock = NSLock()
    private var snapshots: [RunLifecycleSnapshot] = []
    private var waiter: CheckedContinuation<RunLifecycleSnapshot?, Never>?
    private var onTermination: (@Sendable () -> Void)?
    private var isFinished = false
    private var isIteratorClaimed = false

    init(limit: Int, onTermination: (@Sendable () -> Void)? = nil) {
        precondition(limit > 0)
        self.limit = limit
        self.onTermination = onTermination
    }

    func claimIterator() -> Bool {
        lock.withLock {
            guard !isIteratorClaimed else { return false }
            isIteratorClaimed = true
            return true
        }
    }

    func push(_ snapshot: RunLifecycleSnapshot) {
        let waiting: CheckedContinuation<RunLifecycleSnapshot?, Never>?
        lock.lock()
        if isFinished {
            waiting = nil
        } else if let waiter {
            self.waiter = nil
            waiting = waiter
        } else {
            enqueue(snapshot)
            waiting = nil
        }
        lock.unlock()
        waiting?.resume(returning: snapshot)
    }

    func next() async -> RunLifecycleSnapshot? {
        if Task.isCancelled {
            finish()
            return nil
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let delivery = prepareNext(continuation)
                switch delivery {
                case let .snapshot(snapshot):
                    continuation.resume(returning: snapshot)
                case .finished:
                    continuation.resume(returning: nil)
                case .waiting:
                    break
                }
            }
        } onCancel: {
            self.finish()
        }
    }

    func finish() {
        let waiting: CheckedContinuation<RunLifecycleSnapshot?, Never>?
        let termination: (@Sendable () -> Void)?
        lock.lock()
        if isFinished {
            waiting = nil
            termination = nil
        } else {
            isFinished = true
            snapshots.removeAll()
            waiting = waiter
            waiter = nil
            termination = onTermination
            onTermination = nil
        }
        lock.unlock()
        waiting?.resume(returning: nil)
        termination?()
    }

    private func prepareNext(
        _ continuation: CheckedContinuation<RunLifecycleSnapshot?, Never>
    ) -> Delivery {
        lock.lock()
        defer { lock.unlock() }
        if !snapshots.isEmpty {
            return .snapshot(snapshots.removeFirst())
        }
        guard !isFinished else { return .finished }
        guard waiter == nil else { return .finished }
        waiter = continuation
        return .waiting
    }

    private func enqueue(_ snapshot: RunLifecycleSnapshot) {
        if snapshot.isActive,
           let latest = snapshots.last,
           latest.isActive,
           latest.runID == snapshot.runID {
            snapshots[snapshots.count - 1] = snapshot
        } else {
            snapshots.append(snapshot)
        }

        while snapshots.count > limit {
            let newestIndex = snapshots.index(before: snapshots.endIndex)
            if let activeIndex = snapshots.indices.first(where: { index in
                index != newestIndex && snapshots[index].isActive
            }) {
                snapshots.remove(at: activeIndex)
            } else {
                snapshots.removeFirst()
            }
        }
    }
}

private final class LifecycleLease: @unchecked Sendable {
    private let buffer: LifecycleUpdateBuffer

    init(buffer: LifecycleUpdateBuffer) {
        self.buffer = buffer
    }

    deinit {
        buffer.finish()
    }
}
