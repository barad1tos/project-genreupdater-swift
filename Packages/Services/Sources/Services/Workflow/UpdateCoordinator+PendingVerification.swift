import Core

extension UpdateCoordinator {
    /// Resolve a pending album through the API path and apply the resolved year to all album tracks.
    public func verifyPendingAlbum(
        _ entry: PendingAlbumEntry,
        albumTracks: [Track]
    ) async throws -> PendingAlbumVerificationResult {
        guard !albumTracks.isEmpty else {
            return PendingAlbumVerificationResult(entries: [], resolvedYear: nil)
        }

        let yearResult = await apiOrchestrator.getAlbumYear(
            artist: entry.artist,
            album: entry.album,
            currentLibraryYear: nil,
            earliestTrackAddedYear: earliestAddedYear(albumTracks)
        )

        guard let year = yearResult.year else {
            return PendingAlbumVerificationResult(entries: [], resolvedYear: nil)
        }

        var entries: [ChangeLogEntry] = []
        for track in albumTracks where track.year != year {
            let change = ProposedChange(
                track: track,
                changeType: .yearUpdate,
                oldValue: track.year.map(String.init),
                newValue: String(year),
                confidence: yearResult.confidence,
                source: yearResult.isDefinitive ? "Definitive" : "API"
            )
            try await applyChange(change)
            entries.append(Self.changeToLogEntry(change))
        }

        return PendingAlbumVerificationResult(entries: entries, resolvedYear: year)
    }
}
