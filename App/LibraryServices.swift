// LibraryServices.swift -- library cache, sync, and maintenance helpers.

import Core
import Foundation
import Services

private let libraryServicesLog = AppLogger.make(category: "dependencies")

private let openRunReportStates = Set(RunLifecycleState.allCases.filter(isOpenReportState))
private func isOpenReportState(_ state: RunLifecycleState) -> Bool {
    switch state {
    case .created,
         .queued,
         .syncingLibrary,
         .analyzingDelta,
         .planningFixes,
         .awaitingReview,
         .writing,
         .verifying,
         .reporting,
         .blocked,
         .recoverable,
         .recovering:
        true
    case .completed,
         .completedNoOp,
         .failed,
         .cancelled:
        false
    }
}

enum AppDependencyServiceError: LocalizedError, Equatable {
    case librarySyncUnavailable
    case recoveryBlocked
    case recoveryUpdateRequired
    case recoveryUnavailable
    case runRecordStoreUnavailable
    case runOrchestratorUnavailable

    var errorDescription: String? {
        switch self {
        case .librarySyncUnavailable:
            "Library sync service is unavailable"
        case .recoveryBlocked:
            "Recovery needs attention before this run can be closed"
        case .recoveryUpdateRequired:
            "Update GenreUpdater before reviewing this recovery"
        case .recoveryUnavailable:
            "Recovery service is unavailable"
        case .runRecordStoreUnavailable:
            "Run record store is unavailable"
        case .runOrchestratorUnavailable:
            "Run orchestrator is unavailable"
        }
    }
}

extension AppDependencies {
    @discardableResult
    func refreshTrackIDMappingOrThrow(
        musicKitTracks: [Track],
        scopedArtists: [String]? = nil,
        mergeExisting: Bool = false
    ) async throws -> Int {
        guard let mapper = trackIDMapper,
              let bridge = applescriptBridge
        else { return 0 }

        let mappedCount = try await mapper.refreshMapping(
            musicKitTracks: musicKitTracks,
            appleScriptClient: bridge,
            batchSize: config.applescript.batchProcessing.idsBatchSize,
            allTrackIDsTimeout: config.applescript.timeouts.fullLibraryFetch,
            tracksByIDsTimeout: config.applescript.timeouts.idsBatchFetch,
            testArtists: scopedArtists ?? config.development.testArtists,
            mergeExisting: mergeExisting
        )
        libraryServicesLog
            .info(
                "Track ID mapping refreshed: \(mappedCount, privacy: .public)/\(musicKitTracks.count, privacy: .public)"
            )
        return mappedCount
    }

    func loadLibrarySnapshot() async -> [Track]? {
        guard let librarySnapshotService else { return nil }

        do {
            return try await librarySnapshotService.loadSnapshot()
        } catch {
            libraryServicesLog
                .warning("Failed to load library snapshot: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func persistLoadedLibraryTracks(
        _ tracks: [Track],
        scopedArtists capturedScopedArtists: [String]? = nil
    ) async {
        let scopedArtists = capturedScopedArtists ?? ArtistAllowList.normalized(config.development.testArtists)
        guard !tracks.isEmpty else { return }
        let previousTracks = await loadPreviousIncrementalScopeTracks()
        replacePreviousIncrementalScopeTracks(previousTracks)

        do {
            try await trackStore?.saveTracks(tracks)
        } catch {
            libraryServicesLog.error("Failed to persist loaded tracks: \(error.localizedDescription, privacy: .public)")
        }

        if scopedArtists.isEmpty {
            do {
                _ = try await librarySnapshotService?.saveSnapshot(tracks)
            } catch {
                libraryServicesLog
                    .warning("Failed to save library snapshot: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func loadPreviousIncrementalScopeTracks() async -> [Track] {
        guard let trackStore else { return [] }
        do {
            return try await trackStore.loadAllTracks()
        } catch {
            libraryServicesLog.warning(
                "Failed to load previous incremental scope tracks: \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    func runMaintenancePreflight() async -> MaintenancePreflightResult? {
        guard let maintenanceCoordinator else { return nil }

        let result = await maintenanceCoordinator.runPreflight()
        maintenancePreflightResult = result

        if let error = result.databaseVerificationError {
            libraryServicesLog.warning("Maintenance preflight database verification failed: \(error, privacy: .public)")
        }
        if result.isPendingVerificationDue {
            libraryServicesLog.info("Maintenance preflight found pending albums due for verification")
        }

        return result
    }

    func submitManualRun() async throws -> RunSubmissionResult {
        try await submitRun { knownTrackCount in
            .manualObservation(
                requestedTestArtists: config.development.testArtists,
                knownTrackCount: knownTrackCount
            )
        }
    }

    func submitFixPlanWrite(input: FixPlanWriteInput) async throws -> RunSubmissionResult {
        guard let runOrchestrator else {
            throw AppDependencyServiceError.runOrchestratorUnavailable
        }
        return await runOrchestrator.submit(.manualWrite(input: input))
    }

    func submitPreviewRun(
        factoryOverrides: APIClientFactoryOverrides = APIClientFactoryOverrides()
    ) async throws -> RunSubmissionResult {
        guard let runOrchestrator else {
            throw AppDependencyServiceError.runOrchestratorUnavailable
        }
        let requestedTestArtists = config.development.testArtists
        let reference = config.yearRetrieval.apiAuth.discogsTokenReference
        var factoryOverrides = factoryOverrides
        factoryOverrides.discogsCredentialIssueHandler = { [weak self] issue in
            guard let self,
                  self.config.yearRetrieval.apiAuth.discogsTokenReference == reference else { return }
            self.setDiscogsIssue(issue)
        }
        let discogsAccess = Self.captureDiscogsAccess(
            configuration: config,
            factoryOverrides: factoryOverrides
        )
        let configuration = capturePreviewConfig(at: Date(), hasDiscogsAccess: discogsAccess.isEnabled)
        let knownTrackCount = await currentKnownTrackCount()
        await discogsAccessStore.save(discogsAccess, configurationID: configuration.id)
        return await runOrchestrator.submit(.manualPreview(
            configuration: configuration,
            requestedTestArtists: requestedTestArtists,
            knownTrackCount: knownTrackCount
        ))
    }

    private func submitRun(makeRequest: (Int?) -> RunRequest) async throws -> RunSubmissionResult {
        guard let runOrchestrator else {
            throw AppDependencyServiceError.runOrchestratorUnavailable
        }

        let knownTrackCount = await currentKnownTrackCount()
        return await runOrchestrator.submit(makeRequest(knownTrackCount))
    }

    func currentRunLifecycle() async -> RunLifecycleSnapshot? {
        await runOrchestrator?.currentLifecycle()
    }

    var isManualRunAvailable: Bool {
        runOrchestrator != nil
    }

    func runLifecycleUpdates() async -> LifecycleUpdates {
        guard let runOrchestrator else {
            libraryServicesLog.warning("Run lifecycle updates requested before run orchestrator is available")
            return .finished
        }

        return await runOrchestrator.lifecycleUpdates()
    }

    func loadRunReportPage(limit: Int) async -> RunReportPage? {
        guard let runRecordStore else {
            libraryServicesLog.warning("Run report page requested before run record store is available")
            return nil
        }

        do {
            let recentPage = try await runRecordStore.reports(matching: RunReportQuery(limit: limit))
            let openPage = try await runRecordStore.reports(matching: RunReportQuery(states: openRunReportStates))
            let recoveryPage = try await runRecordStore.recoveryRecords()
            return mergeRunReportPages(mergeRunReportPages(recentPage, openPage), recoveryPage)
        } catch {
            libraryServicesLog.error(
                """
                Failed to load run report page: \
                \(String(describing: type(of: error)), privacy: .public): \
                \(error.localizedDescription, privacy: .private)
                """
            )
            return nil
        }
    }

    private func mergeRunReportPages(_ recentPage: RunReportPage, _ openPage: RunReportPage) -> RunReportPage {
        var seen = Set<UUID>()
        let openRecords = openPage.records.filter { $0.finishedAt == nil }
        let records = (recentPage.records + openRecords).filter { record in
            seen.insert(record.runID.rawValue).inserted
        }
        var seenCorrupted = Set<RunID>()
        let corruptedRunIDs = (recentPage.corruptedRunIDs + openPage.corruptedRunIDs).filter {
            seenCorrupted.insert($0).inserted
        }
        var seenRecovery = Set<RunID>()
        let recoveryRunIDs = (recentPage.recoveryRunIDs + openPage.recoveryRunIDs).filter {
            seenRecovery.insert($0).inserted
        }
        var seenClosable = Set<RunID>()
        let closableRunIDs = (recentPage.closableRunIDs + openPage.closableRunIDs).filter {
            seenClosable.insert($0).inserted
        }
        var seenAttention = Set<RunID>()
        let attentionRunIDs = (recentPage.attentionRunIDs + openPage.attentionRunIDs).filter {
            seenAttention.insert($0).inserted
        }
        var seenUnsupported = Set<RunID>()
        let unsupportedRunIDs = (recentPage.unsupportedRunIDs + openPage.unsupportedRunIDs).filter {
            seenUnsupported.insert($0).inserted
        }
        let duplicatedCorruptedCount = Set(recentPage.corruptedRunIDs)
            .intersection(openPage.corruptedRunIDs)
            .count

        return RunReportPage(
            records: records,
            skippedCorruptedCount: recentPage.skippedCorruptedCount
                + openPage.skippedCorruptedCount
                - duplicatedCorruptedCount,
            corruptedRunIDs: corruptedRunIDs,
            recoveryRunIDs: recoveryRunIDs,
            closableRunIDs: closableRunIDs,
            attentionRunIDs: attentionRunIDs,
            unsupportedRunIDs: unsupportedRunIDs
        )
    }

    func loadRunReportRecord(id: String) async -> RunRecord? {
        guard let runRecordStore else {
            libraryServicesLog.warning("Run report record requested before run record store is available")
            return nil
        }

        guard let runID = UUID(uuidString: id) else {
            libraryServicesLog.error("Run report record request had a malformed id: \(id, privacy: .private)")
            return nil
        }

        do {
            return try await runRecordStore.record(for: RunID(rawValue: runID))
        } catch {
            libraryServicesLog.error(
                """
                Failed to load run report record \(runID.uuidString, privacy: .public): \
                \(String(describing: type(of: error)), privacy: .public): \
                \(error.localizedDescription, privacy: .private)
                """
            )
            return nil
        }
    }

    func refreshAutoSyncStatus() async {
        isAutoSyncRunning = await librarySyncService?.isAutoSyncRunning ?? false
    }

    func setAutoSyncEnabled(_ isEnabled: Bool) async throws {
        guard let librarySyncService else {
            throw AppDependencyServiceError.librarySyncUnavailable
        }

        if isEnabled {
            let interval = Duration.seconds(max(1, config.runtime.incrementalIntervalMinutes) * 60)
            try await librarySyncService.startAutoSync(interval: interval)
        } else {
            await librarySyncService.stopAutoSync()
        }
        isAutoSyncRunning = await librarySyncService.isAutoSyncRunning
    }

    private func currentKnownTrackCount() async -> Int? {
        if let trackCountSource {
            return await trackCountSource()
        }
        guard let trackStore else { return nil }

        do {
            return try await trackStore.trackCount()
        } catch {
            libraryServicesLog.warning(
                """
                Failed to read known track count for run scope snapshot: \
                \(error.localizedDescription, privacy: .private)
                """
            )
            return nil
        }
    }
}
