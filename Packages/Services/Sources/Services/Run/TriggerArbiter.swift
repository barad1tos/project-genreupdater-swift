import Foundation

struct PendingTrigger: Equatable {
    let request: RunRequest
}

enum TriggerArbiter {
    enum Decision: Equatable {
        case alreadyCovered(PendingTrigger?)
        case queue(PendingTrigger)
    }

    static func decide(
        active: RunLifecycleSnapshot,
        pending: PendingTrigger?,
        incoming: RunRequest
    ) -> Decision {
        let incomingKey = RequestKey(request: incoming)
        let activeKey = RequestKey(lifecycle: active)
        let pendingKey = pending.map { RequestKey(request: $0.request) }
        let candidateKeys = [activeKey, pendingKey].compactMap(\.self)
        let strongestRank = candidateKeys.map(\.rank).max() ?? activeKey.rank

        if incomingKey.rank < strongestRank {
            return .alreadyCovered(pending)
        }

        if incomingKey.rank == strongestRank {
            let isCovered = candidateKeys.contains { key in
                key.rank == strongestRank && key.scope.covers(incomingKey.scope)
            }
            return isCovered ? .alreadyCovered(pending) : .queue(PendingTrigger(request: incoming))
        }

        return .queue(PendingTrigger(request: incoming))
    }

    fileprivate static func rank(trigger: RunTrigger, intent: RunIntent) -> RequestRank {
        RequestRank(triggerPriority: trigger.priority, intentPriority: intent.priority)
    }
}

private struct RequestKey {
    let rank: RequestRank
    let scope: ScopeKey

    init(lifecycle: RunLifecycleSnapshot) {
        rank = TriggerArbiter.rank(trigger: lifecycle.trigger, intent: lifecycle.intent)
        scope = ScopeKey(snapshot: lifecycle.scope)
    }

    init(request: RunRequest) {
        rank = TriggerArbiter.rank(trigger: request.trigger, intent: request.intent)
        scope = ScopeKey(request: request)
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

private struct ScopeKey: Equatable {
    let source: ProcessingScopeSource
    let artists: [String]
    let knownTrackCount: Int?

    init(snapshot: ProcessingScopeSnapshot) {
        source = snapshot.source
        artists = snapshot.normalizedTestArtists
        knownTrackCount = snapshot.knownTrackCount
    }

    init(request: RunRequest) {
        self.init(snapshot: .capture(
            requestedTestArtists: request.requestedTestArtists,
            knownTrackCount: request.knownTrackCount,
            createdAt: Date(timeIntervalSince1970: 0),
            reason: request.trigger.rawValue
        ))
    }

    func covers(_ other: Self) -> Bool {
        guard knownTrackCount == other.knownTrackCount else { return false }
        switch (source, other.source) {
        case (.fullLibrary, _):
            return true
        case (.testArtists, .testArtists):
            return artists == other.artists
        case (.testArtists, .fullLibrary):
            return false
        }
    }
}

private enum TriggerPriority {
    static let backgroundSync = 0
    static let fileSystemEvent = 1
    static let manualCheck = 2
    static let recovery = 3
}

private enum IntentPriority {
    static let observeLibrary = 0
    static let previewFixes = 1
}

extension RunTrigger {
    fileprivate var priority: Int {
        switch self {
        case .backgroundSync: TriggerPriority.backgroundSync
        case .fileSystemEvent: TriggerPriority.fileSystemEvent
        case .manualCheck: TriggerPriority.manualCheck
        case .recovery: TriggerPriority.recovery
        }
    }
}

extension RunIntent {
    fileprivate var priority: Int {
        switch self {
        case .observeLibrary: IntentPriority.observeLibrary
        case .previewFixes: IntentPriority.previewFixes
        }
    }
}
