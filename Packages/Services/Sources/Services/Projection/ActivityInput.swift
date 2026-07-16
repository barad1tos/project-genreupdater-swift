import Core
import Foundation

public enum ActivityLibraryState: Equatable, Sendable {
    case empty
    case loading
    case ready
    case permissionDenied(String)
    case failed(String)
}

public struct ActivityProjectionMetrics: Equatable, Sendable {
    public let totalTracks: Int
    public let tracksWithGenre: Int
    public let tracksWithYear: Int
    public let tracksWithBoth: Int
    public let protectedFileCount: Int?
    public let recentlyAdded: Int
    public let snapshotDate: Date?

    public init(
        totalTracks: Int,
        tracksWithGenre: Int,
        tracksWithYear: Int,
        tracksWithBoth: Int,
        protectedFileCount: Int?,
        recentlyAdded: Int,
        snapshotDate: Date?
    ) {
        self.totalTracks = totalTracks
        self.tracksWithGenre = tracksWithGenre
        self.tracksWithYear = tracksWithYear
        self.tracksWithBoth = tracksWithBoth
        self.protectedFileCount = protectedFileCount
        self.recentlyAdded = recentlyAdded
        self.snapshotDate = snapshotDate
    }
}

public struct ActivityWorkflowState: Equatable, Sendable {
    public static let empty = Self(
        proposedChangeCount: 0,
        acceptedChangeCount: 0,
        failedWriteCount: 0,
        isProcessing: false,
        phaseLabel: "Idle"
    )

    public let proposedChangeCount: Int
    public let acceptedChangeCount: Int
    public let failedWriteCount: Int
    public let isProcessing: Bool
    public let phaseLabel: String

    public init(
        proposedChangeCount: Int,
        acceptedChangeCount: Int,
        failedWriteCount: Int,
        isProcessing: Bool,
        phaseLabel: String
    ) {
        self.proposedChangeCount = proposedChangeCount
        self.acceptedChangeCount = acceptedChangeCount
        self.failedWriteCount = failedWriteCount
        self.isProcessing = isProcessing
        self.phaseLabel = phaseLabel
    }
}

public struct ActivityFixPlanSummary: Equatable, Sendable {
    public let status: FixPlanProjectionStatus
    public let itemCount: Int
    public let acceptedCount: Int
    public let canApply: Bool

    public var isReviewable: Bool {
        itemCount > 0 && (status == .ready || status == .stale)
    }

    public init(
        status: FixPlanProjectionStatus,
        itemCount: Int,
        acceptedCount: Int,
        canApply: Bool
    ) {
        self.status = status
        self.itemCount = itemCount
        self.acceptedCount = acceptedCount
        self.canApply = canApply
    }

    public init(projection: FixPlanProjection) {
        self.init(
            status: projection.status,
            itemCount: projection.itemCount,
            acceptedCount: projection.acceptedCount,
            canApply: projection.canApply
        )
    }
}

public struct ActivityRecoverySummary: Equatable, Sendable {
    public let unresolvedRunCount: Int
    public let latestRecoveryRunID: String?

    public var isActive: Bool {
        unresolvedRunCount > 0
    }

    public init(unresolvedRunCount: Int, latestRecoveryRunID: String?) {
        self.unresolvedRunCount = unresolvedRunCount
        self.latestRecoveryRunID = latestRecoveryRunID
    }
}

public struct ActivityPendingVerificationSummary: Equatable, Sendable {
    public let total: Int
    public let due: Int
    public let problematic: Int
    public let skippedByInterval: Int
    public let verified: Int

    public init(total: Int, due: Int, problematic: Int, skippedByInterval: Int, verified: Int) {
        self.total = total
        self.due = due
        self.problematic = problematic
        self.skippedByInterval = skippedByInterval
        self.verified = verified
    }
}

public struct ActivityProjectionInput: Equatable, Sendable {
    public let tracks: [Track]
    public let metrics: ActivityProjectionMetrics?
    public let lastScanDate: Date?
    public let libraryState: ActivityLibraryState
    public let processingMode: ActivityProcessingMode
    public let workflow: ActivityWorkflowState
    public let fixPlan: ActivityFixPlanSummary?
    public let recovery: ActivityRecoverySummary?
    public let pendingVerification: ActivityPendingVerificationSummary?
    public let runLifecycle: RunLifecycleSnapshot?
    public let isLibrarySyncAvailable: Bool
    public let isAutoSyncRunning: Bool
    public let now: Date

    public var effectiveLastScanDate: Date? {
        lastScanDate ?? metrics?.snapshotDate
    }

    public var proposedFixCount: Int {
        guard let fixPlan, fixPlan.isReviewable else {
            return workflow.proposedChangeCount
        }
        return fixPlan.itemCount
    }

    public var acceptedFixCount: Int {
        guard let fixPlan, fixPlan.isReviewable else {
            return workflow.acceptedChangeCount
        }
        return fixPlan.acceptedCount
    }

    public var hasRecovery: Bool {
        recovery?.isActive == true
    }

    public var effectiveSyncState: ActivitySyncState {
        guard let runLifecycle else { return .idle }

        switch runLifecycle.phase {
        case .active(.awaitingReview):
            return .awaitingReview
        case .active:
            return .running
        case let .finished(.completed(result), _),
             let .finished(.completedNoOp(result), _):
            return .completed(ActivitySyncSummary(result: result))
        case let .finished(.failed(message), _):
            return .failed(message)
        case let .finished(.cancelled(message), _):
            return .cancelled(message)
        case .suspended(.blocked):
            // Suspended states are generic until RunSuspendedState carries user-facing reasons.
            return .blocked("Run blocked")
        case .suspended(.recoverable):
            return .recoveryNeeded("Recovery needed")
        }
    }

    public init(
        tracks: [Track],
        metrics: ActivityProjectionMetrics?,
        lastScanDate: Date?,
        libraryState: ActivityLibraryState,
        processingMode: ActivityProcessingMode,
        workflow: ActivityWorkflowState,
        fixPlan: ActivityFixPlanSummary? = nil,
        recovery: ActivityRecoverySummary? = nil,
        pendingVerification: ActivityPendingVerificationSummary?,
        runLifecycle: RunLifecycleSnapshot? = nil,
        isLibrarySyncAvailable: Bool,
        isAutoSyncRunning: Bool,
        now: Date
    ) {
        self.tracks = tracks
        self.metrics = metrics
        self.lastScanDate = lastScanDate
        self.libraryState = libraryState
        self.processingMode = processingMode
        self.workflow = workflow
        self.fixPlan = fixPlan
        self.recovery = recovery
        self.pendingVerification = pendingVerification
        self.runLifecycle = runLifecycle
        self.isLibrarySyncAvailable = isLibrarySyncAvailable
        self.isAutoSyncRunning = isAutoSyncRunning
        self.now = now
    }
}
