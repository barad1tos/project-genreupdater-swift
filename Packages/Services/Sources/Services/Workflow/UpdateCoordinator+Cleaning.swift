import Core

extension UpdateCoordinator {
    static func determineCleaningChanges(
        track: Track,
        options: UpdateOptions,
        cleaning: CleaningConfig
    ) -> [ProposedChange] {
        guard options.cleanTrackNames || options.cleanAlbumNames else { return [] }

        let cleaned = cleanNames(
            artist: track.artist,
            trackName: track.name,
            albumName: track.album,
            config: cleaning
        )
        var changes: [ProposedChange] = []

        if options.cleanTrackNames,
           cleaned.cleanedTrack != normalizedMetadataForComparison(track.name) {
            changes.append(ProposedChange(
                track: track,
                changeType: .trackCleaning,
                oldValue: track.name,
                newValue: cleaned.cleanedTrack,
                confidence: 100,
                source: "Cleaning"
            ))
        }

        if options.cleanAlbumNames,
           cleaned.cleanedAlbum != normalizedMetadataForComparison(track.album) {
            changes.append(ProposedChange(
                track: track,
                changeType: .albumCleaning,
                oldValue: track.album,
                newValue: cleaned.cleanedAlbum,
                confidence: 100,
                source: "Cleaning"
            ))
        }

        return changes
    }

    private static func normalizedMetadataForComparison(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
