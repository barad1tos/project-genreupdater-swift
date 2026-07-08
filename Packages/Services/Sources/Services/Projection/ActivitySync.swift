import Foundation

public struct ActivitySyncSummary: Codable, Equatable, Sendable {
    public let new: Int
    public let modified: Int
    public let identityChanged: Int
    public let refreshed: Int
    public let removed: Int

    public var changeCount: Int {
        new + modified + identityChanged + refreshed + removed
    }

    var resultDetail: String {
        changeCount == 0 ? "No library changes detected" : "\(changeCount.formatted()) library changes detected"
    }

    public init(new: Int, modified: Int, identityChanged: Int, refreshed: Int, removed: Int) {
        self.new = new
        self.modified = modified
        self.identityChanged = identityChanged
        self.refreshed = refreshed
        self.removed = removed
    }

    public init(result: SyncResult) {
        self.init(
            new: result.newTracks.count,
            modified: result.modifiedTracks.count,
            identityChanged: result.identityChangedTracks.count,
            refreshed: result.refreshedTracks.count,
            removed: result.removedTrackIDs.count
        )
    }
}

public enum ActivitySyncState: Equatable, Sendable {
    case idle
    case running
    case awaitingReview
    case completed(ActivitySyncSummary)
    case failed(String)
    case blocked(String)
    case cancelled(String)
    case recoveryNeeded(String)
}

extension ActivitySyncState {
    var summary: ActivitySyncSummary? {
        guard case let .completed(summary) = self else { return nil }
        return summary
    }

    var title: String? {
        switch self {
        case .running:
            "Syncing library"
        case .awaitingReview:
            "Awaiting review"
        case .failed:
            "Sync needs attention"
        case .blocked:
            "Run blocked"
        case .cancelled:
            "Run cancelled"
        case .recoveryNeeded:
            "Recovery needed"
        case .idle, .completed:
            nil
        }
    }

    var subtitle: String? {
        switch self {
        case .running:
            "Manual sync running · detecting library delta"
        case .awaitingReview:
            "Review changes before writing"
        case let .failed(message), let .blocked(message), let .cancelled(message), let .recoveryNeeded(message):
            message
        case .idle, .completed:
            nil
        }
    }

    var statusText: String? {
        switch self {
        case .running:
            "Syncing"
        case .awaitingReview:
            "Awaiting review"
        case .failed:
            "Sync failed"
        case .blocked:
            "Blocked"
        case .cancelled:
            "Cancelled"
        case .recoveryNeeded:
            "Recovery needed"
        case let .completed(summary):
            summary.changeCount > 0 ? "Synced · \(summary.changeCount.formatted()) changes" : "Synced · no changes"
        case .idle:
            nil
        }
    }

    var detectDetail: String? {
        switch self {
        case .running:
            "Detecting delta"
        case .failed:
            "Sync failed"
        case .awaitingReview:
            "Awaiting review"
        case .blocked:
            "Run blocked"
        case .cancelled:
            "Run cancelled"
        case .recoveryNeeded:
            "Recovery needed"
        case .idle, .completed:
            nil
        }
    }

    var recentIssue: ActivityRecentItem? {
        switch self {
        case let .failed(message):
            ActivityRecentItem(id: "library-sync-error", title: "Library sync failed", detail: message)
        case let .blocked(message):
            ActivityRecentItem(id: "run-blocked", title: "Run blocked", detail: message)
        case let .cancelled(message):
            ActivityRecentItem(id: "run-cancelled", title: "Run cancelled", detail: message)
        case let .recoveryNeeded(message):
            ActivityRecentItem(id: "recovery-needed", title: "Recovery needed", detail: message)
        case .idle, .running, .awaitingReview, .completed:
            nil
        }
    }

    var operationalIssue: OperationalIssue? {
        switch self {
        case let .failed(message):
            OperationalIssue(
                id: "library-sync-failed",
                category: .temporaryUnavailable,
                summary: "Library sync failed",
                technicalDetail: message
            )
        case let .blocked(message):
            OperationalIssue(
                id: "run-blocked",
                category: .safetyBlocked,
                summary: "Run blocked",
                technicalDetail: message
            )
        case let .recoveryNeeded(message):
            OperationalIssue(
                id: "recovery-needed",
                category: .recoveryRequired,
                summary: "Recovery needed",
                technicalDetail: message
            )
        case .idle, .running, .awaitingReview, .completed, .cancelled:
            nil
        }
    }

    var requiresRecoveryAttention: Bool {
        switch self {
        case .blocked, .recoveryNeeded:
            true
        case .idle, .running, .awaitingReview, .completed, .failed, .cancelled:
            false
        }
    }

    var activeStage: ActivityPipelineStage? {
        switch self {
        case .running, .failed, .cancelled:
            .detect
        case .awaitingReview:
            .diff
        case .blocked, .recoveryNeeded:
            .fix
        case .idle, .completed:
            nil
        }
    }
}
