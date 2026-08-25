import Core

extension LibrarySyncService {
    var libraryReadRequest: LibraryReadRequest {
        LibraryReadRequest(
            testArtists: runtimeConfiguration.testArtists,
            albumIdentity: runtimeConfiguration.albumTargetIdentity
        )
    }

    /// BASELINE scope: allow-list only. Identity narrowing deliberately
    /// stays OUT of ID-set arithmetic — filtering the stored/library
    /// baselines by album would convert album-tag drift into deletions
    /// and explode newIDs in the fallback path (PR #163 review).
    func tracksInConfiguredScope(_ tracks: [Track]) -> [Track] {
        ArtistAllowList.filter(tracks, allowedArtists: runtimeConfiguration.testArtists)
    }

    /// RESULT admission: the full predicate (allow-list + album identity),
    /// applied after the observer supplies authoritative source metadata.
    func tracksAdmittedByRequest(_ tracks: [Track]) -> [Track] {
        let request = libraryReadRequest
        return tracks.filter { request.admits($0) }
    }
}
