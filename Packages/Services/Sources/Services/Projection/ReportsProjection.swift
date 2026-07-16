import Foundation

public enum ReportsRunState: String, Equatable, Sendable {
    case running
    case awaitingReview
    case completed
    case completedNoOp
    case blocked
    case failed
    case cancelled
    case recoveryNeeded
}

public struct ReportsRunItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let state: ReportsRunState
    public let stateLabel: String
    public let triggerLabel: String
    public let startedLabel: String
    public let modeLabel: String
    public let scopeLabel: String
    public let durationLabel: String?
    public let changeCountLabel: String?
    public let failureSummary: String?

    public init(
        id: String,
        state: ReportsRunState,
        stateLabel: String,
        triggerLabel: String,
        startedLabel: String,
        modeLabel: String,
        scopeLabel: String,
        durationLabel: String?,
        changeCountLabel: String?,
        failureSummary: String?
    ) {
        self.id = id
        self.state = state
        self.stateLabel = stateLabel
        self.triggerLabel = triggerLabel
        self.startedLabel = startedLabel
        self.modeLabel = modeLabel
        self.scopeLabel = scopeLabel
        self.durationLabel = durationLabel
        self.changeCountLabel = changeCountLabel
        self.failureSummary = failureSummary
    }
}

public struct ReportsProjection: Equatable, Sendable {
    public let revision: ProjectionRevision
    public let runs: [ReportsRunItem]
    public let skippedCorruptedCount: Int
    public let recoveryRunIDs: [String]

    public init(
        revision: ProjectionRevision,
        runs: [ReportsRunItem],
        skippedCorruptedCount: Int,
        recoveryRunIDs: [String] = []
    ) {
        self.revision = revision
        self.runs = runs
        self.skippedCorruptedCount = skippedCorruptedCount
        self.recoveryRunIDs = recoveryRunIDs
    }

    public func withRevision(_ revision: ProjectionRevision) -> Self {
        Self(
            revision: revision,
            runs: runs,
            skippedCorruptedCount: skippedCorruptedCount,
            recoveryRunIDs: recoveryRunIDs
        )
    }

    public static func empty(revision: ProjectionRevision = .initial) -> Self {
        Self(revision: revision, runs: [], skippedCorruptedCount: 0, recoveryRunIDs: [])
    }
}
