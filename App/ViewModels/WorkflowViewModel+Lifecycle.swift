// WorkflowViewModel+Lifecycle.swift -- Workflow reset and default handling.

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
        minConfidence: Double
    ) {
        defaultUpdateGenre = updateGenre
        defaultUpdateYear = updateYear
        defaultPreviewOnly = previewOnly
        defaultMinConfidence = minConfidence

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
    }

    private func applyDefaultConfiguration() {
        updateGenre = defaultUpdateGenre
        updateYear = defaultUpdateYear
        cleanTrackNames = false
        cleanAlbumNames = false
        previewOnly = defaultPreviewOnly
        minConfidence = defaultMinConfidence
    }
}
