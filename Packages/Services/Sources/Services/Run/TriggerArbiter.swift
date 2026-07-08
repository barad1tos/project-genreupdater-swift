import Foundation

struct PendingTrigger: Equatable, Sendable {
    let request: RunRequest
    let coalescedTriggers: [RunTrigger]

    init(request: RunRequest, coalescedTriggers: [RunTrigger]? = nil) {
        self.request = request
        self.coalescedTriggers = coalescedTriggers ?? [request.trigger]
    }

    func coalescing(_ trigger: RunTrigger) -> Self {
        guard !coalescedTriggers.contains(trigger) else { return self }
        return Self(request: request, coalescedTriggers: coalescedTriggers + [trigger])
    }
}

enum TriggerArbiter {
    enum Decision: Equatable, Sendable {
        case alreadyCovered(PendingTrigger?)
        case queue(PendingTrigger)
    }

    static func decide(
        active: RunLifecycleSnapshot,
        pending: PendingTrigger?,
        incoming: RunRequest
    ) -> Decision {
        let incomingRank = rank(trigger: incoming.trigger, intent: incoming.intent)
        let activeRank = rank(trigger: active.trigger, intent: active.intent)
        let pendingRank = pending.map { rank(trigger: $0.request.trigger, intent: $0.request.intent) }
        let strongestRank = [activeRank, pendingRank].compactMap(\.self).max() ?? activeRank

        guard incomingRank > strongestRank else {
            return .alreadyCovered(pending?.coalescing(incoming.trigger))
        }

        let coalescedTriggers = pending.map { $0.coalescedTriggers + [incoming.trigger] } ?? [incoming.trigger]
        return .queue(PendingTrigger(request: incoming, coalescedTriggers: coalescedTriggers.uniqued()))
    }

    private static func rank(trigger: RunTrigger, intent: RunIntent) -> RequestRank {
        RequestRank(triggerPriority: trigger.priority, intentPriority: intent.priority)
    }
}

private struct RequestRank: Comparable {
    let triggerPriority: Int
    let intentPriority: Int

    static func < (left: Self, right: Self) -> Bool {
        if left.triggerPriority == right.triggerPriority {
            return left.intentPriority < right.intentPriority
        }
        return left.triggerPriority < right.triggerPriority
    }
}

extension RunTrigger {
    fileprivate var priority: Int {
        switch self {
        case .backgroundSync: 0
        case .fileSystemEvent: 1
        case .manualCheck: 2
        case .recovery: 3
        }
    }
}

extension RunIntent {
    fileprivate var priority: Int {
        switch self {
        case .observeLibrary: 0
        case .previewFixes: 1
        }
    }
}

extension Array where Element: Equatable {
    fileprivate func uniqued() -> Self {
        reduce(into: []) { result, element in
            guard !result.contains(element) else { return }
            result.append(element)
        }
    }
}
