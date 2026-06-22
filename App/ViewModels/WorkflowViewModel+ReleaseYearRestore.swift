// WorkflowViewModel+ReleaseYearRestore.swift -- Release-year restore workflow.

import Core
import Services

extension WorkflowViewModel {
    func startReleaseYearRestore(tracks: [Track]) {
        let scopedTracks = Self.tracksNeedingReleaseYearRestore(
            tracks,
            threshold: releaseYearRestoreThreshold
        )
        prepareReleaseYearRestoreRun(scopedTracks: scopedTracks)

        processingTask = Task {
            let restoreResult = await updateCoordinator.restoreReleaseYears(
                in: scopedTracks,
                threshold: releaseYearRestoreThreshold,
                progressHandler: { [weak self] update in
                    Task { @MainActor in
                        self?.handleReleaseYearRestoreProgress(update, tracksByIndex: scopedTracks)
                    }
                }
            )

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
    private func prepareReleaseYearRestoreRun(scopedTracks: [Track]) {
        phase = .applying
        processedCount = 0
        failedCount = 0
        totalCount = scopedTracks.count
        currentTrackID = nil
        proposedChanges = []
        completedEntries = []
        result = nil
        dryRunReport = nil
        trackStatuses = Dictionary(uniqueKeysWithValues: scopedTracks.map { ($0.id, .queued) })
    }

    private func handleReleaseYearRestoreProgress(
        _ update: ProgressUpdate,
        tracksByIndex: [Track]
    ) {
        progress = update
        processedCount = update.current

        if update.current > 0, update.current <= tracksByIndex.count {
            let currentTrack = tracksByIndex[update.current - 1]
            currentTrackID = currentTrack.id
            trackStatuses[currentTrack.id] = .writing

            if update.current > 1 {
                let previousTrack = tracksByIndex[update.current - 2]
                if case .writing = trackStatuses[previousTrack.id] {
                    trackStatuses[previousTrack.id] = .done
                }
            }
        }

        if update.phase == .complete, let lastTrack = tracksByIndex.last {
            if case .writing = trackStatuses[lastTrack.id] {
                trackStatuses[lastTrack.id] = .done
            }
        }
    }

    private func finishReleaseYearRestore(_ restoreResult: BatchUpdateResult) {
        result = restoreResult
        completedEntries = restoreResult.entries
        failedCount = restoreResult.failedTrackIDs.count
        currentTrackID = nil
        phase = .done
        progress = nil
    }
}
