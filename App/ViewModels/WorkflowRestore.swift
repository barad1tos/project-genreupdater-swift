// WorkflowRestore.swift -- Release-year restore workflow.

import Core
import Services

extension WorkflowViewModel {
    func startReleaseYearRestore(tracks: [Track]) {
        let scopedTracks = Self.tracksNeedingReleaseYearRestore(
            tracks,
            threshold: releaseYearRestoreThreshold
        )

        processingTask = Task {
            guard await !stopForRecoveryHold() else { return }
            let runGeneration = prepareReleaseYearRestoreRun(scopedTracks: scopedTracks)
            let progressHandler = makeReleaseYearRestoreProgressHandler(
                scopedTracks: scopedTracks,
                runGeneration: runGeneration
            )

            guard await prepareMutationMetadataIfNeeded(tracks: scopedTracks) else { return }
            let restoreResult = await updateCoordinator.restoreReleaseYears(
                in: scopedTracks,
                threshold: releaseYearRestoreThreshold,
                progressHandler: progressHandler
            )

            guard !Task.isCancelled else {
                if isCurrentReleaseYearRestoreRun(runGeneration) {
                    finishCancelledProcessing()
                }
                return
            }
            guard isCurrentReleaseYearRestoreRun(runGeneration) else { return }
            finishReleaseYearRestore(restoreResult)
        }
    }

    static func tracksNeedingReleaseYearRestore(
        _ tracks: [Track],
        threshold: Int
    ) -> [Track] {
        UpdateCoordinator.tracksNeedingReleaseYearRestore(tracks, threshold: threshold)
    }
}

extension WorkflowViewModel {
    @discardableResult
    func invalidateReleaseYearRestoreRuns() -> Int {
        releaseYearRestoreRunGeneration += 1
        return releaseYearRestoreRunGeneration
    }

    private func isCurrentReleaseYearRestoreRun(_ runGeneration: Int) -> Bool {
        mode == .releaseYearRestore && runGeneration == releaseYearRestoreRunGeneration
    }

    private func prepareReleaseYearRestoreRun(scopedTracks: [Track]) -> Int {
        let runGeneration = invalidateReleaseYearRestoreRuns()
        phase = .applying
        processedCount = 0
        failedCount = 0
        totalCount = scopedTracks.count
        currentTrackID = nil
        proposedChanges = []
        completedEntries = []
        result = nil
        dryRunReport = nil
        maintenancePreflightResult = nil
        recoveryReportSummary = nil
        trackStatuses = Dictionary(uniqueKeysWithValues: scopedTracks.map { ($0.id, .queued) })
        return runGeneration
    }

    private func makeReleaseYearRestoreProgressHandler(
        scopedTracks: [Track],
        runGeneration: Int
    ) -> @Sendable (ProgressUpdate) -> Void {
        { [weak self] update in
            Task { @MainActor in
                guard let self,
                      self.isCurrentReleaseYearRestoreRun(runGeneration) else { return }
                self.handleReleaseYearRestoreProgress(update, tracksByIndex: scopedTracks)
            }
        }
    }

    private func handleReleaseYearRestoreProgress(
        _ update: ProgressUpdate,
        tracksByIndex: [Track]
    ) {
        progress = update
        processedCount = update.current

        guard update.current > 0, update.current <= tracksByIndex.count else { return }

        let currentTrack = tracksByIndex[update.current - 1]
        currentTrackID = currentTrack.id
        trackStatuses[currentTrack.id] = .writing

        let previousTrack = update.current > 1 ? tracksByIndex[update.current - 2] : nil
        if let previousTrack,
           case .writing = trackStatuses[previousTrack.id] {
            trackStatuses[previousTrack.id] = .done
        }

        if update.phase == .complete,
           let lastTrack = tracksByIndex.last,
           case .writing = trackStatuses[lastTrack.id] {
            trackStatuses[lastTrack.id] = .done
        }
    }

    private func finishReleaseYearRestore(_ restoreResult: BatchUpdateResult) {
        result = restoreResult
        recoveryReportSummary = UpdateRunRecoverySummary(result: restoreResult)
        completedEntries = restoreResult.entries
        var terminalTrackIDs = Set(restoreResult.entries.map(\.trackID))
        terminalTrackIDs.formUnion(restoreResult.noOpEntries.map(\.trackID))
        terminalTrackIDs.formUnion(restoreResult.failedTrackIDs)
        for trackID in Array(trackStatuses.keys) where !terminalTrackIDs.contains(trackID) {
            trackStatuses[trackID] = .skipped
        }
        for (index, trackID) in restoreResult.failedTrackIDs.enumerated() {
            trackStatuses[trackID] = .failed(
                restoreResult.errorDescriptions[safe: index] ?? "No failure details were captured for this run."
            )
        }
        failedCount = failedTracks.count
        currentTrackID = nil
        phase = .done
        progress = nil
    }
}
