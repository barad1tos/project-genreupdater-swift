// WorkflowViewModel+Lifecycle.swift -- Workflow reset and default handling.

import Core
import Services

extension WorkflowViewModel {
    func cancel() {
        processingTask?.cancel()
        processingTask = nil
        if mode == .fullLibrary {
            Task { await batchProcessor.cancel() }
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
        phase = .configure
        progress = nil
        proposedChanges = []
        result = nil
        completedEntries = []
        dryRunReport = nil
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
        releaseYearRestoreThreshold = defaultReleaseYearRestoreThreshold
    }

    func enableWritesForReviewedChanges() {
        guard case .review = phase else { return }
        previewOnly = false
        dryRunReport = nil
    }

    func configureSelectedTracksScope(
        tracks: [Core.Track],
        updateGenre: Bool,
        updateYear: Bool,
        previewOnly: Bool
    ) {
        reset()
        mode = .selectedTracks
        self.updateGenre = updateGenre
        self.updateYear = updateYear
        self.previewOnly = previewOnly
        computeScopePreview(tracks: tracks)
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
