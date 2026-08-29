import Core

struct ProcessingTrackScope: Sendable, Equatable {
    let testArtists: [String]
    let albumIdentity: AlbumIdentity?

    init(testArtists: [String] = [], albumIdentity: AlbumIdentity? = nil) {
        self.testArtists = ArtistAllowList.normalized(testArtists)
        self.albumIdentity = albumIdentity
    }

    func admits(_ track: Track) -> Bool {
        guard ArtistAllowList.containsNormalized(track, in: testArtists) else {
            return false
        }
        guard let albumIdentity else { return true }
        return AlbumIdentity.lookupKeys(for: track).contains(albumIdentity.key)
    }
}

extension LibrarySyncService {
    func processingScope(configuration: LibrarySyncRuntimeConfiguration) -> ProcessingTrackScope {
        ProcessingTrackScope(
            testArtists: configuration.testArtists,
            albumIdentity: configuration.albumTargetIdentity
        )
    }

    /// BASELINE scope: allow-list only. Identity narrowing deliberately
    /// stays OUT of ID-set arithmetic — filtering the stored/library
    /// baselines by album would convert album-tag drift into deletions
    /// and explode newIDs in the fallback path (PR #163 review).
    func tracksInConfiguredScope(
        _ tracks: [Track],
        configuration: LibrarySyncRuntimeConfiguration
    ) -> [Track] {
        ArtistAllowList.filter(tracks, allowedArtists: configuration.testArtists)
    }

    /// RESULT admission: the full predicate (allow-list + album identity),
    /// applied after the observer supplies authoritative source metadata.
    func tracksAdmittedByRequest(
        _ tracks: [Track],
        configuration: LibrarySyncRuntimeConfiguration
    ) -> [Track] {
        let scope = processingScope(configuration: configuration)
        return tracks.filter { scope.admits($0) }
    }
}
