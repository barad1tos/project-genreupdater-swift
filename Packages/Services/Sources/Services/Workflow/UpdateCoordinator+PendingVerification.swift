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

        let identity = Self.pendingVerificationIdentity(for: entry, albumTracks: albumTracks)
        let yearResult = await apiOrchestrator.getAlbumYear(
            artist: identity.artist,
            album: identity.album,
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

    private static func pendingVerificationIdentity(
        for entry: PendingAlbumEntry,
        albumTracks: [Track]
    ) -> AlbumIdentity {
        let pendingKeys = Set(AlbumIdentity.lookupKeys(artist: entry.artist, album: entry.album))
        let matchingTrack = albumTracks.first { track in
            let trackKeys = Set(AlbumIdentity.lookupKeys(for: track))
            return !pendingKeys.isDisjoint(with: trackKeys)
        }
        return (matchingTrack ?? albumTracks[0]).albumIdentity
    }
}
