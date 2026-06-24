import Core

extension UpdateCoordinator {
    static func cleaningOutcome(
        track: Track,
        options: UpdateOptions,
        cleaning: CleaningConfig
    ) -> (track: Track, changes: [ProposedChange]) {
        guard options.cleanTrackNames || options.cleanAlbumNames else {
            return (track, [])
        }

        let cleaned = cleanNames(
            artist: track.artist,
            trackName: track.name,
            albumName: track.album,
            config: cleaning
        )
        var workingTrack = track
        var changes: [ProposedChange] = []

        if options.cleanTrackNames,
           !cleaned.cleanedTrack.isEmpty,
           cleaned.cleanedTrack != normalizedMetadataForComparison(track.name) {
            changes.append(ProposedChange(
                track: track,
                changeType: .trackCleaning,
                oldValue: track.name,
                newValue: cleaned.cleanedTrack,
                confidence: 100,
                source: "Cleaning"
            ))
            workingTrack.name = cleaned.cleanedTrack
        }

        if options.cleanAlbumNames,
           !cleaned.cleanedAlbum.isEmpty,
           cleaned.cleanedAlbum != normalizedMetadataForComparison(track.album) {
            changes.append(ProposedChange(
                track: track,
                changeType: .albumCleaning,
                oldValue: track.album,
                newValue: cleaned.cleanedAlbum,
                confidence: 100,
                source: "Cleaning"
            ))
            workingTrack.album = cleaned.cleanedAlbum
        }

        return (workingTrack, changes)
    }

    private static func normalizedMetadataForComparison(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
