import Core
import Foundation
import Services

/// Adapter grouping of the dependency-graph library facts (the load
/// chain is their sole writer); kept below the parameter ceiling.
struct ActivityLibraryFacts {
    let tracks: [Core.Track]
    let metricsSnapshot: MetricsSnapshotValues?
    let lastScanDate: Date?
    let loadError: LibraryLoadError?
    let isLoading: Bool
    let readiness: MirrorReadiness

    init(
        tracks: [Core.Track],
        metricsSnapshot: MetricsSnapshotValues?,
        lastScanDate: Date?,
        loadError: LibraryLoadError?,
        isLoading: Bool,
        readiness: MirrorReadiness = .incomplete(.freshObservationRequired)
    ) {
        self.tracks = tracks
        self.metricsSnapshot = metricsSnapshot
        self.lastScanDate = lastScanDate
        self.loadError = loadError
        self.isLoading = isLoading
        self.readiness = readiness
    }

    @MainActor static let empty = Self(
        tracks: [],
        metricsSnapshot: nil,
        lastScanDate: nil,
        loadError: nil,
        isLoading: false,
        readiness: .incomplete(.freshObservationRequired)
    )
}

/// Workflow view-model facts, marked inputs until slice 11 moves
/// ownership behind the run orchestrator.
struct ActivityWorkflowFacts {
    let dashboard: WorkflowDashboardState
    let pendingVerification: UpdateRunPendingVerificationSummary?

    @MainActor static let empty = Self(dashboard: .empty, pendingVerification: nil)
}

struct LibraryReadinessCopy: Equatable {
    let detail: String
    let buttonTitle: String

    init?(_ readiness: MirrorReadiness) {
        switch readiness {
        case .ready:
            return nil
        case .stale(.membershipChanged):
            detail = "Music library changed · refresh before updating"
            buttonTitle = "Refresh Required"
        case .stale(.metadataExpired):
            detail = "Music metadata expired · refresh before updating"
            buttonTitle = "Refresh Required"
        case .stale(.supersededRevision):
            detail = "Library mirror changed · reload before updating"
            buttonTitle = "Reload Required"
        case .incomplete(.freshObservationRequired):
            detail = "Refresh Music metadata before updating"
            buttonTitle = "Refresh Required"
        case let .incomplete(.identityMissing(count)):
            detail = "\(count.formatted()) tracks need identity repair before updating"
            buttonTitle = "Repair Required"
        case let .incomplete(.metadataMissing(count)):
            detail = "\(count.formatted()) tracks need metadata refresh before updating"
            buttonTitle = "Refresh Required"
        case .incomplete(.narrowedObservation):
            detail = "Run a full scope refresh before updating"
            buttonTitle = "Refresh Required"
        case let .unavailable(failure):
            detail = "Library readiness unavailable: \(failure.detail)"
            buttonTitle = "Library Unavailable"
        }
    }
}

struct ActivityInputContext {
    let tracks: [Core.Track]
    let reportEntries: [Core.ChangeLogEntry]
    let metricsSnapshot: MetricsSnapshotValues?
    let lastScanDate: Date?
    let loadError: LibraryLoadError?
    let isLoading: Bool
    var readiness: MirrorReadiness = .incomplete(.freshObservationRequired)
    let isDryRun: Bool
    let workflow: WorkflowDashboardState
    let fixPlanProjection: FixPlanProjection
    let reportsProjection: ReportsProjection
    let queuedWrite: ActivityQueuedWriteSummary?
    let pendingVerification: UpdateRunPendingVerificationSummary?
    var mirrorEffectIssue: OperationalIssue?
    let runLifecycle: RunLifecycleSnapshot?
    let isLibrarySyncAvailable: Bool
    let isAutomationArmed: Bool
    let now: Date
}

/// Backend-owned activity assembly (ADR 0013): the host supplies the
/// facts it still loads; projections, queued-write truth, and
/// MainActor configuration are read here — and the publish happens
/// here, never in view code.
extension AppDependencies {
    /// Host-supplied facts land in the bridge cache so every later
    /// publisher (the lifecycle observer, command handlers) reuses the
    /// same truth the host last loaded.
    @discardableResult
    func refreshActivityProjection(
        library: ActivityLibraryFacts,
        workflow: ActivityWorkflowFacts
    ) async -> ActivityProjection {
        // External facts land on the dependency graph (the load chain
        // is the production writer; tests use this seam directly). The
        // workflow facts install as a provider — the same path
        // production publishes through.
        libraryTracks = library.tracks
        libraryMetrics = library.metricsSnapshot
        lastLibraryScanDate = library.lastScanDate
        libraryLoadError = library.loadError
        isLibraryLoading = library.isLoading
        libraryReadiness = library.readiness
        workflowFactsProvider = { workflow }
        // The lifecycle observer is the SOLE writer of the lifecycle
        // snapshot: a host mirror can lag its own subscription, and
        // writing it back here would revert newer run truth.
        return await republishActivityProjection()
    }

    /// Rebuilds activity from the cached facts plus current lifecycle.
    @discardableResult
    func republishActivityProjection() async -> ActivityProjection {
        let library = ActivityLibraryFacts(
            tracks: libraryTracks,
            metricsSnapshot: libraryMetrics,
            lastScanDate: lastLibraryScanDate,
            loadError: libraryLoadError,
            isLoading: isLibraryLoading,
            readiness: libraryReadiness
        )
        let workflow = workflowFactsProvider?() ?? .empty
        let runLifecycle = currentLifecycleSnapshot
        // Synchronous MainActor facts first so the snapshot cannot tear
        // across the awaits below (D3).
        let isDryRun = config.runtime.dryRun
        let isLibrarySyncAvailable = isManualRunAvailable
        let isAutomationArmedNow = isAutomationArmed

        let inputGeneration = await projectionStore.nextActivityProjectionInputGeneration()
        let queuedWrite = await queuedWriteSummary()
        let fixPlan = await projectionStore.fixPlanProjection()
        let reports = await projectionStore.reportsProjection()
        let reportEntries = await (try? changeLogStore?.loadRecent(
            limit: ActivityReportFacts.entryLimit
        )) ?? []

        let input = ActivityInputBuilder.makeInput(from: ActivityInputContext(
            tracks: library.tracks,
            reportEntries: reportEntries,
            metricsSnapshot: library.metricsSnapshot,
            lastScanDate: library.lastScanDate,
            loadError: library.loadError,
            isLoading: library.isLoading,
            readiness: library.readiness,
            isDryRun: isDryRun,
            workflow: workflow.dashboard,
            fixPlanProjection: fixPlan,
            reportsProjection: reports,
            queuedWrite: queuedWrite,
            pendingVerification: workflow.pendingVerification,
            mirrorEffectIssue: mirrorEffectDrainIssue,
            runLifecycle: runLifecycle,
            isLibrarySyncAvailable: isLibrarySyncAvailable,
            isAutomationArmed: isAutomationArmedNow,
            now: Date()
        ))
        return await projectionStore.replaceActivityProjection(
            ActivityBuilder.makeProjection(from: input),
            inputGeneration: inputGeneration
        )
    }
}

enum ActivityInputBuilder {
    static func makeInput(from context: ActivityInputContext) -> ActivityProjectionInput {
        ActivityProjectionInput(
            tracks: context.tracks,
            reportEntries: context.reportEntries,
            metrics: makeMetrics(from: context.metricsSnapshot),
            lastScanDate: context.lastScanDate,
            libraryState: makeLibraryState(
                loadError: context.loadError,
                isLoading: context.isLoading,
                tracks: context.tracks,
                readiness: context.readiness
            ),
            processingMode: context.isDryRun ? .preview : .autoFix,
            workflow: makeWorkflowState(from: context.workflow),
            fixPlan: makeFixPlanSummary(from: context.fixPlanProjection),
            recovery: makeRecoverySummary(from: context.reportsProjection),
            queuedWrite: context.queuedWrite,
            pendingVerification: makePendingVerification(from: context.pendingVerification),
            mirrorEffectIssue: context.mirrorEffectIssue,
            runLifecycle: context.runLifecycle,
            isLibrarySyncAvailable: context.isLibrarySyncAvailable,
            isAutomationArmed: context.isAutomationArmed,
            now: context.now
        )
    }

    private static func makeMetrics(from metricsSnapshot: MetricsSnapshotValues?) -> ActivityProjectionMetrics? {
        guard let metricsSnapshot else { return nil }
        return ActivityProjectionMetrics(
            totalTracks: metricsSnapshot.totalTracks,
            tracksWithGenre: metricsSnapshot.tracksWithGenre,
            tracksWithYear: metricsSnapshot.tracksWithYear,
            tracksWithBoth: metricsSnapshot.tracksWithBoth,
            protectedFileCount: metricsSnapshot.protectedFileCount,
            recentlyAdded: metricsSnapshot.recentlyAdded,
            snapshotDate: metricsSnapshot.timestamp
        )
    }

    private static func makeLibraryState(
        loadError: LibraryLoadError?,
        isLoading: Bool,
        tracks: [Core.Track],
        readiness: MirrorReadiness
    ) -> ActivityLibraryState {
        if let loadError {
            switch loadError {
            case .permissionDenied:
                return .permissionDenied(loadError.message)
            case .restricted, .nonCanonicalMirror, .failed:
                return .failed(loadError.message)
            }
        }
        if isLoading {
            return .loading
        }
        if let copy = LibraryReadinessCopy(readiness) {
            return .presentationOnly(copy.detail)
        }
        return tracks.isEmpty ? .empty : .ready
    }

    private static func makeWorkflowState(from workflow: WorkflowDashboardState) -> ActivityWorkflowState {
        ActivityWorkflowState(
            proposedChangeCount: workflow.proposedChangeCount,
            acceptedChangeCount: workflow.acceptedChangeCount,
            failedWriteCount: workflow.failedWriteCount,
            isProcessing: workflow.isProcessing,
            phaseLabel: workflow.phaseLabel
        )
    }

    private static func makeFixPlanSummary(from projection: FixPlanProjection) -> ActivityFixPlanSummary? {
        guard projection.status != .empty else { return nil }
        return ActivityFixPlanSummary(projection: projection)
    }

    private static func makeRecoverySummary(from projection: ReportsProjection) -> ActivityRecoverySummary? {
        guard !projection.recoveryRunIDs.isEmpty else { return nil }
        return ActivityRecoverySummary(
            unresolvedRunCount: projection.recoveryRunIDs.count,
            latestRecoveryRunID: projection.recoveryRunIDs.first
        )
    }

    private static func makePendingVerification(
        from summary: UpdateRunPendingVerificationSummary?
    ) -> ActivityPendingVerificationSummary? {
        guard let summary else { return nil }
        return ActivityPendingVerificationSummary(
            total: summary.total,
            due: summary.due,
            problematic: summary.problematic,
            skippedByInterval: summary.skippedByInterval,
            verified: summary.verified
        )
    }
}
