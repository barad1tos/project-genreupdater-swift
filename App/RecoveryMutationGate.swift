import Foundation

actor RecoveryMutationGate {
    private var activeIDs: Set<UUID> = []
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ id: UUID) async {
        guard activeIDs.contains(id) else {
            activeIDs.insert(id)
            return
        }
        await withCheckedContinuation { continuation in
            waiters[id, default: []].append(continuation)
        }
    }

    func release(_ id: UUID) {
        guard var queued = waiters[id], !queued.isEmpty else {
            activeIDs.remove(id)
            waiters[id] = nil
            return
        }
        let next = queued.removeFirst()
        waiters[id] = queued.isEmpty ? nil : queued
        next.resume()
    }
}
