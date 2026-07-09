import Core

extension UpdateCoordinator {
    static func cleaningOutcome(
        policyTrack: Track,
        proposalTrack: Track,
        options: UpdateOptions,
        cleaning: CleaningConfig
    ) -> (track: Track, changes: [ProposedChange]) {
        guard options.cleanTrackNames || options.cleanAlbumNames else {
            return (policyTrack, [])
        }

        let cleaned = cleanNames(
            artist: policyTrack.artist,
            trackName: policyTrack.name,
            albumName: policyTrack.album,
            config: cleaning
        )
        var workingTrack = policyTrack
        var changes: [ProposedChange] = []

        if options.cleanTrackNames,
           !cleaned.cleanedTrack.isEmpty,
           cleaned.cleanedTrack != normalizedMetadataForComparison(policyTrack.name) {
            changes.append(ProposedChange(
                track: proposalTrack,
                changeType: .trackCleaning,
                oldValue: proposalTrack.name,
                newValue: cleaned.cleanedTrack,
                confidence: 100,
                source: "Cleaning"
            ))
            workingTrack.name = cleaned.cleanedTrack
        }

        if options.cleanAlbumNames,
           !cleaned.cleanedAlbum.isEmpty,
           cleaned.cleanedAlbum != normalizedMetadataForComparison(policyTrack.album) {
            changes.append(ProposedChange(
                track: proposalTrack,
                changeType: .albumCleaning,
                oldValue: proposalTrack.album,
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
