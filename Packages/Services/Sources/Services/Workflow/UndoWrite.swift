import Core

enum UndoWrite {
    static func reconciledChange(_ change: ProposedChange, currentTrack: Track) -> ProposedChange {
        let albumArtistChange = reconciledAlbumArtist(
            change.albumArtistChange,
            currentValue: currentTrack.albumArtist
        )
        return ProposedChange(
            id: change.id,
            track: currentTrack,
            changeType: change.changeType,
            oldValue: change.oldValue,
            newValue: change.newValue,
            confidence: change.confidence,
            source: change.source,
            isAccepted: change.isAccepted,
            albumArtistChange: albumArtistChange
        )
    }

    static func dispatch(
        _ write: PreparedWrite,
        scriptBridge: any AppleScriptClient,
        attemptState: WriteAttemptState
    ) async throws -> AppleScriptWriteResult {
        guard write.updates.count > 1 else {
            return try await scriptBridge.updateTrackProperty(
                trackID: write.trackID,
                property: write.property,
                value: write.value,
                onAttempt: { attemptState.markAttempted() }
            )
        }

        try await scriptBridge.batchUpdateTracks(
            write.updates,
            onAttempt: { attemptState.markAttempted() }
        )
        return .changed
    }

    private static func reconciledAlbumArtist(
        _ change: AlbumArtistChange?,
        currentValue: String?
    ) -> AlbumArtistChange? {
        guard let change, let currentValue else { return nil }
        let normalizedCurrent = normalizeForMatching(currentValue)
        let expectedValues = [change.oldValue, change.newValue].map(normalizeForMatching)
        return expectedValues.contains(normalizedCurrent) ? change : nil
    }
}
