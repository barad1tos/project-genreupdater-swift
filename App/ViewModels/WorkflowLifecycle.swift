// WorkflowLifecycle.swift -- Workflow reset and default handling.

import Core
import Services

extension WorkflowViewModel {
    func cancel() {
        let wasProcessing = isProcessing
        invalidateReleaseYearRestoreRuns()
        processingTask?.cancel()
        processingTask = nil
        if mode == .releaseYearRestore, wasProcessing {
            // Release-year restore invalidates run generations before its task can
            // observe cancellation, so clear visible processing state immediately.
            finishCancelledProcessing()
        }
        // A queued or submitted batch has no running processor to cancel:
        // purging the pending trigger and the stash makes cancel real
        // before the run ever starts; the fallback (a trigger that
        // escaped the purge) finds no stash and records cancelled. The
        // stash gate — not the mode — decides: applyAccepted runs in
        // smart-filter and pending-verification modes too.
        let hadPendingBatch = pendingBatchExecution != nil
        if hadPendingBatch {
            pendingBatchExecution = nil
            trackStatuses = [:]
            finishCancelledProcessing()
        }
        if mode == .fullLibrary || hadPendingBatch {
            Task { [discardQueuedBatchRuns, batchProcessor] in
                await discardQueuedBatchRuns?()
                await batchProcessor.cancel()
            }
        }
    }

    func updateDefaults(
        updateGenre: Bool,
        updateYear: Bool,
        previewOnly: Bool,
        minConfidence: Double,
        releaseYearRestoreThreshold: Int
    ) {
        defaultUpdateGenre = updateGenre
        defaultUpdateYear = updateYear
        defaultPreviewOnly = previewOnly
        defaultMinConfidence = minConfidence
        defaultReleaseYearRestoreThreshold = releaseYearRestoreThreshold

        guard canStart else { return }
        applyDefaultConfiguration()
    }

    func reset() {
        cancel()
        invalidatePendingVerificationRefreshes()
        phase = .configure
        progress = nil
        proposedChanges = []
        result = nil
        completedEntries = []
        maintenancePreflightResult = nil
        processedCount = 0
        totalCount = 0
        failedCount = 0
        applyDefaultConfiguration()
        trackStatuses = [:]
        currentTrackID = nil
        scopeTrackCount = 0
        scopeArtistCount = 0
        pendingAlbumCount = 0
        pendingDueAlbumCount = 0
        pendingSkippedAlbumCount = 0
        pendingVerificationReportSummary = nil
        recoveryReportSummary = nil
        capturedRunFacts = nil
        releaseYearRestoreThreshold = defaultReleaseYearRestoreThreshold
    }

    func enableWritesForReviewedChanges() {
        guard case .review = phase else { return }
        previewOnly = false
    }

    func configureFullLibraryScope(tracks: [Core.Track]) {
        reset()
        mode = .fullLibrary
        computeScopePreview(tracks: tracks)
    }

    private func applyDefaultConfiguration() {
        updateGenre = defaultUpdateGenre
        updateYear = defaultUpdateYear
        forceYearLookup = false
        cleanTrackNames = false
        cleanAlbumNames = false
        previewOnly = defaultPreviewOnly
        minConfidence = defaultMinConfidence
        releaseYearRestoreThreshold = defaultReleaseYearRestoreThreshold
    }

    func toggleChange(at index: Int) {
        guard proposedChanges.indices.contains(index) else { return }
        changePreviewPipeline.toggle(&proposedChanges[index])
    }

    func acceptAll() {
        changePreviewPipeline.acceptAll(&proposedChanges)
    }

    func rejectAll() {
        changePreviewPipeline.rejectAll(&proposedChanges)
    }
}
