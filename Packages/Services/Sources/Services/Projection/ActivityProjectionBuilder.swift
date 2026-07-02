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

public struct ActivitySyncSummary: Equatable, Sendable {
    public let new: Int
    public let modified: Int
    public let identityChanged: Int
    public let refreshed: Int
    public let removed: Int

    public var changeCount: Int {
        new + modified + identityChanged + refreshed + removed
    }

    public init(new: Int, modified: Int, identityChanged: Int, refreshed: Int, removed: Int) {
        self.new = new
        self.modified = modified
        self.identityChanged = identityChanged
        self.refreshed = refreshed
        self.removed = removed
    }
}

public enum ActivitySyncState: Equatable, Sendable {
    case idle
    case running
    case completed(ActivitySyncSummary)
    case failed(String)
}

public struct ActivityProjectionInput: Equatable, Sendable {
    public let tracks: [Track]
    public let metrics: ActivityProjectionMetrics?
    public let lastScanDate: Date?
    public let libraryState: ActivityLibraryState
    public let processingMode: ActivityProcessingMode
    public let workflow: ActivityWorkflowState
    public let pendingVerification: ActivityPendingVerificationSummary?
    public let runLifecycle: RunLifecycleSnapshot?
    public let syncState: ActivitySyncState
    public let isLibrarySyncAvailable: Bool
    public let isAutoSyncRunning: Bool
    public let now: Date

    public var effectiveLastScanDate: Date? {
        lastScanDate ?? metrics?.snapshotDate
    }

    public var effectiveSyncState: ActivitySyncState {
        guard let runLifecycle else { return syncState }

        switch runLifecycle.state {
        case .created, .syncingLibrary:
            return .running
        case .completed, .completedNoOp:
            guard let syncResult = runLifecycle.syncResult else {
                assertionFailure("Completed run lifecycle requires a SyncResult")
                return syncState
            }
            return .completed(ActivitySyncSummary(
                new: syncResult.newTracks.count,
                modified: syncResult.modifiedTracks.count,
                identityChanged: syncResult.identityChangedTracks.count,
                refreshed: syncResult.refreshedTracks.count,
                removed: syncResult.removedTrackIDs.count
            ))
        case .failed:
            return .failed(runLifecycle.failureMessage ?? "Run failed")
        }
    }

    public init(
        tracks: [Track],
        metrics: ActivityProjectionMetrics?,
        lastScanDate: Date?,
        libraryState: ActivityLibraryState,
        processingMode: ActivityProcessingMode,
        workflow: ActivityWorkflowState,
        pendingVerification: ActivityPendingVerificationSummary?,
        runLifecycle: RunLifecycleSnapshot? = nil,
        syncState: ActivitySyncState,
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
        self.pendingVerification = pendingVerification
        self.runLifecycle = runLifecycle
        self.syncState = syncState
        self.isLibrarySyncAvailable = isLibrarySyncAvailable
        self.isAutoSyncRunning = isAutoSyncRunning
        self.now = now
    }
}

public enum ActivityProjectionBuilder {
    public static func makeProjection(from input: ActivityProjectionInput) -> ActivityProjection {
        let counts = makeCounts(from: input)
        let syncSummary = makeSyncSummary(from: input.effectiveSyncState)
        let currentStage = makeCurrentStage(input: input)
        let stageDescriptors = makeStageDescriptors(input: input, currentStage: currentStage, syncSummary: syncSummary)
        let issues = makeOperationalIssues(from: input)

        return ActivityProjection(
            revision: .initial,
            title: makeTitle(input: input),
            subtitle: makeSubtitle(input: input, syncSummary: syncSummary),
            syncStatusText: makeSyncStatusText(input: input, syncSummary: syncSummary),
            currentStage: currentStage,
            processingMode: input.processingMode,
            automationState: makeAutomationState(input: input),
            deltaCount: makeDeltaCount(input: input, syncSummary: syncSummary),
            interventionCount: input.pendingVerification?.total ?? 0,
            protectedCount: counts.protectedFileCount,
            failedWriteCount: input.workflow.failedWriteCount,
            isUndoReady: false,
            primaryCommand: makePrimaryCommand(input: input),
            secondaryCommand: makeRunManuallyCommand(input: input),
            stageDescriptors: stageDescriptors,
            recentActivity: makeRecentActivity(input: input, counts: counts, syncSummary: syncSummary),
            summaryCards: makeSummaryCards(input: input, counts: counts, syncSummary: syncSummary),
            operationalIssues: issues
        )
    }

    private static func makeDeltaCount(
        input: ActivityProjectionInput,
        syncSummary: ActivitySyncSummary?
    ) -> Int {
        if input.workflow.proposedChangeCount > 0 {
            return input.workflow.proposedChangeCount
        }
        return syncSummary?.changeCount ?? 0
    }

    private struct Counts {
        let totalTracks: Int
        let tracksWithBoth: Int
        let protectedFileCount: Int
    }

    private static func makeCounts(from input: ActivityProjectionInput) -> Counts {
        if let metrics = input.metrics {
            return Counts(
                totalTracks: metrics.totalTracks,
                tracksWithBoth: metrics.tracksWithBoth,
                protectedFileCount: metrics.protectedFileCount ?? 0
            )
        }

        let tracksWithBoth = input.tracks.count(where: { isPresent($0.genre) && $0.year != nil })
        return Counts(
            totalTracks: input.tracks.count,
            tracksWithBoth: tracksWithBoth,
            protectedFileCount: 0
        )
    }

    private static func makeTitle(input: ActivityProjectionInput) -> String {
        switch input.libraryState {
        case .permissionDenied, .failed:
            return "Library needs attention"
        case .loading:
            return "Scanning library"
        case .empty:
            return "Library empty"
        case .ready:
            break
        }

        switch input.effectiveSyncState {
        case .running:
            return "Syncing library"
        case .failed:
            return "Sync needs attention"
        case .idle, .completed:
            break
        }

        if input.workflow.isProcessing {
            return input.workflow.phaseLabel
        }
        if input.workflow.proposedChangeCount > 0 {
            return "Fix plan ready"
        }
        return "Library ready"
    }

    private static func makeSubtitle(input: ActivityProjectionInput, syncSummary: ActivitySyncSummary?) -> String {
        if let libraryStateSubtitle = makeLibraryStateSubtitle(input: input) {
            return libraryStateSubtitle
        }

        switch input.effectiveSyncState {
        case .running:
            return "Manual sync running · detecting library delta"
        case let .failed(message):
            return message
        case .idle:
            break
        case .completed:
            if let syncSummary {
                return syncResultDetail(syncSummary)
            }
        }

        if input.workflow.proposedChangeCount > 0 {
            let mode = input.processingMode == .preview ? "preview mode · no Music tags written" : "write mode"
            return "\(input.workflow.proposedChangeCount.formatted()) candidate fixes · \(mode)"
        }

        return "Library ready"
    }

    private static func makeLibraryStateSubtitle(input: ActivityProjectionInput) -> String? {
        switch input.libraryState {
        case let .permissionDenied(message), let .failed(message):
            message
        case .loading:
            input.isAutoSyncRunning ? "Auto-sync running · reading Music metadata" : "Manual scan in progress"
        case .empty:
            input.effectiveSyncState == .idle ? "No Music tracks available for analysis" : nil
        case .ready:
            nil
        }
    }

    private static func makeSyncStatusText(
        input: ActivityProjectionInput,
        syncSummary: ActivitySyncSummary?
    ) -> String {
        switch input.effectiveSyncState {
        case .running:
            return "Syncing"
        case .failed:
            return "Sync failed"
        case .completed:
            if let syncSummary, syncSummary.changeCount > 0 {
                return "Synced · \(syncSummary.changeCount.formatted()) changes"
            }
            return "Synced · no changes"
        case .idle:
            break
        }

        if case .loading = input.libraryState {
            return "Scanning"
        }
        if let lastScanDate = input.effectiveLastScanDate {
            let relativeTime = relativeTime(from: lastScanDate, to: input.now)
            return relativeTime == "just now" ? "Synced just now" : "Synced \(relativeTime) ago"
        }
        return input.isAutoSyncRunning ? "Auto-sync running" : "No sync yet"
    }

    private static func makeAutomationState(input: ActivityProjectionInput) -> ActivityAutomationState {
        if input.isAutoSyncRunning {
            return .autoSyncRunning
        }
        if input.effectiveLastScanDate != nil {
            return .manualScanOnly
        }
        return .noSyncYet
    }

    private static func makeCurrentStage(input: ActivityProjectionInput) -> ActivityPipelineStage {
        switch input.libraryState {
        case .loading, .permissionDenied, .failed:
            return .detect
        case .empty:
            if input.effectiveSyncState == .idle {
                return .watch
            }
        case .ready:
            break
        }

        if case .running = input.effectiveSyncState {
            return .detect
        }
        if case .failed = input.effectiveSyncState {
            return .detect
        }
        if input.workflow.isProcessing || input.workflow.acceptedChangeCount > 0 {
            return .fix
        }
        if input.workflow.proposedChangeCount > 0 {
            return .diff
        }
        if case .completed = input.effectiveSyncState {
            return .diff
        }
        return input.isAutoSyncRunning ? .watch : .detect
    }

    private static func makeStageDescriptors(
        input: ActivityProjectionInput,
        currentStage: ActivityPipelineStage,
        syncSummary: ActivitySyncSummary?
    ) -> [ActivityPipelineStageDescriptor] {
        [
            ActivityPipelineStageDescriptor(
                stage: .watch,
                detail: makeAutomationState(input: input) == .autoSyncRunning ? "Auto-sync running" :
                    "Manual scan only",
                status: watchStatus(input: input, currentStage: currentStage)
            ),
            ActivityPipelineStageDescriptor(
                stage: .detect,
                detail: detectDetail(input: input),
                status: detectStatus(input: input, currentStage: currentStage)
            ),
            ActivityPipelineStageDescriptor(
                stage: .diff,
                detail: syncSummary.map(syncResultDetail) ?? "No delta",
                status: diffStatus(input: input, currentStage: currentStage)
            ),
            ActivityPipelineStageDescriptor(
                stage: .fix,
                detail: input.processingMode == .preview ? "Preview gated" : "Write mode",
                status: fixStatus(input: input, currentStage: currentStage)
            ),
            ActivityPipelineStageDescriptor(
                stage: .verify,
                detail: input.pendingVerification == nil ? "Not available" : "Pending summary",
                status: .pending
            ),
            ActivityPipelineStageDescriptor(stage: .report, detail: "Audit trail", status: .pending)
        ]
    }

    private static func watchStatus(
        input: ActivityProjectionInput,
        currentStage: ActivityPipelineStage
    ) -> ActivityPipelineStageStatus {
        if currentStage == .watch {
            return .current
        }

        switch input.libraryState {
        case .permissionDenied, .failed:
            return .failed
        case .loading, .empty, .ready:
            return .completed
        }
    }

    private static func detectDetail(input: ActivityProjectionInput) -> String {
        switch input.effectiveSyncState {
        case .running:
            "Detecting delta"
        case .failed:
            "Sync failed"
        case .idle, .completed:
            input.isAutoSyncRunning ? "Periodic polling" : "Manual trigger"
        }
    }

    private static func detectStatus(
        input: ActivityProjectionInput,
        currentStage: ActivityPipelineStage
    ) -> ActivityPipelineStageStatus {
        switch input.effectiveSyncState {
        case .running:
            return .current
        case .failed:
            return .failed
        case .completed:
            return currentStage == .detect ? .current : .completed
        case .idle:
            break
        }

        switch input.libraryState {
        case .loading:
            return .current
        case .permissionDenied, .failed:
            return .failed
        case .empty:
            return .pending
        case .ready:
            return currentStage == .detect ? .current : .completed
        }
    }

    private static func diffStatus(
        input: ActivityProjectionInput,
        currentStage: ActivityPipelineStage
    ) -> ActivityPipelineStageStatus {
        if input.workflow.proposedChangeCount > 0 {
            return currentStage == .diff ? .current : .completed
        }
        if case .completed = input.effectiveSyncState {
            return currentStage == .diff ? .current : .completed
        }
        return .pending
    }

    private static func fixStatus(
        input: ActivityProjectionInput,
        currentStage: ActivityPipelineStage
    ) -> ActivityPipelineStageStatus {
        if input.workflow.failedWriteCount > 0 {
            return .failed
        }
        if input.workflow.isProcessing {
            return currentStage == .fix ? .current : .pending
        }
        if input.workflow.proposedChangeCount > 0 || input.workflow.acceptedChangeCount > 0 {
            return input.processingMode == .preview ? .gated : .pending
        }
        return .pending
    }

    private static func makePrimaryCommand(input: ActivityProjectionInput) -> ActivityCommandDescriptor? {
        guard input.workflow.proposedChangeCount > 0 else { return nil }

        return ActivityCommandDescriptor(
            id: "review-changes",
            title: "Review changes",
            style: .primary,
            isEnabled: true,
            commandKind: .reviewChanges
        )
    }

    private static func makeRunManuallyCommand(input: ActivityProjectionInput) -> ActivityCommandDescriptor {
        let isEnabled = input.effectiveSyncState != .running
            && input.isLibrarySyncAvailable
            && !input.workflow.isProcessing
        return ActivityCommandDescriptor(
            id: "run-manually",
            title: input.effectiveSyncState == .running ? "Syncing" : "Run manually",
            style: .secondary,
            isEnabled: isEnabled,
            commandKind: .runManually
        )
    }

    private static func makeRecentActivity(
        input: ActivityProjectionInput,
        counts: Counts,
        syncSummary: ActivitySyncSummary?
    ) -> [ActivityRecentItem] {
        var items: [ActivityRecentItem] = []
        switch input.libraryState {
        case .ready:
            items.append(ActivityRecentItem(
                id: "scan",
                title: "Library scan",
                detail: "\(counts.totalTracks) tracks analyzed"
            ))
        case .loading:
            items.append(ActivityRecentItem(id: "scan", title: "Library scan", detail: "Scanning in progress"))
        case .empty:
            items.append(ActivityRecentItem(id: "scan", title: "Library scan", detail: "No tracks found"))
        case let .permissionDenied(message), let .failed(message):
            items.append(ActivityRecentItem(id: "scan", title: "Library scan", detail: message))
        }

        if let syncSummary {
            items.append(ActivityRecentItem(
                id: "library-sync",
                title: "Library sync",
                detail: syncResultDetail(syncSummary)
            ))
        }
        if case let .failed(message) = input.effectiveSyncState {
            items.append(ActivityRecentItem(id: "library-sync-error", title: "Library sync failed", detail: message))
        }
        return items
    }

    private static func makeSummaryCards(
        input: ActivityProjectionInput,
        counts: Counts,
        syncSummary: ActivitySyncSummary?
    ) -> [ActivitySummaryCard] {
        let automationState = makeAutomationState(input: input)
        let deltaValue: Int
        let deltaDetail: String
        if input.workflow.proposedChangeCount > 0 {
            deltaValue = input.workflow.proposedChangeCount
            deltaDetail = "candidate fixes"
        } else {
            deltaValue = syncSummary?.changeCount ?? 0
            deltaDetail = "library changes"
        }

        return [
            ActivitySummaryCard(
                id: "automation",
                kind: .automation,
                label: "Automation",
                value: automationState == .autoSyncRunning ? "Running" : "Manual",
                detail: automationState == .autoSyncRunning ? "Auto-sync running" : "Manual scan only"
            ),
            ActivitySummaryCard(
                id: "delta",
                kind: .delta,
                label: "Delta",
                value: "\(deltaValue)",
                detail: deltaDetail
            ),
            ActivitySummaryCard(
                id: "quality",
                kind: .quality,
                label: "Quality",
                value: qualityPercentage(from: counts),
                detail: "reporting context"
            )
        ]
    }

    private static func qualityPercentage(from counts: Counts) -> String {
        guard counts.totalTracks > 0 else { return "0%" }
        let percentage = Double(counts.tracksWithBoth) / Double(counts.totalTracks) * 100
        return "\(Int(percentage.rounded()))%"
    }

    private static func makeOperationalIssues(from input: ActivityProjectionInput) -> [OperationalIssue] {
        if case let .failed(message) = input.effectiveSyncState {
            return [
                OperationalIssue(
                    id: "library-sync-failed",
                    category: .temporaryUnavailable,
                    summary: "Library sync failed",
                    technicalDetail: message
                )
            ]
        }
        return []
    }

    private static func makeSyncSummary(from syncState: ActivitySyncState) -> ActivitySyncSummary? {
        guard case let .completed(summary) = syncState else { return nil }
        return summary
    }

    private static func syncResultDetail(_ summary: ActivitySyncSummary) -> String {
        let count = summary.changeCount
        return count == 0 ? "No library changes detected" : "\(count.formatted()) library changes detected"
    }

    private static func relativeTime(from date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 {
            return "just now"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h"
        }
        return "\(hours / 24)d"
    }

    private static func isPresent(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
