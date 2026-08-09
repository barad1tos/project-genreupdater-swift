import Core

struct LibrarySyncAppleScriptScopeSnapshot {
    let trackIDs: [String]
    let tracksByID: [String: Track]?
}

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

    /// RESULT admission: the full predicate (allow-list + album
    /// identity), applied to classification outputs whose tracks carry
    /// authoritative metadata — AppleScript results directly, provider
    /// results only after mutation-metadata enrichment restores the
    /// albumArtist MusicKit strips.
    func tracksAdmittedByRequest(_ tracks: [Track]) -> [Track] {
        let request = libraryReadRequest
        return tracks.filter { request.admits($0) }
    }

    func loadStoredTracksInConfiguredScope() async throws -> [Track] {
        let tracks = try await trackStore.loadAllTracks()
        return tracksInConfiguredScope(tracks)
    }

    func fetchAppleScriptLibrarySnapshotForConfiguredScope() async throws -> LibrarySyncAppleScriptScopeSnapshot {
        guard let scopedTracks = try await fetchAppleScriptTracksForConfiguredScope() else {
            let trackIDs = try await scriptBridge.fetchAllTrackIDs(
                timeout: runtimeConfiguration.fullLibraryFetchTimeout
            )
            return LibrarySyncAppleScriptScopeSnapshot(trackIDs: trackIDs, tracksByID: nil)
        }

        return LibrarySyncAppleScriptScopeSnapshot(
            trackIDs: scopedTracks.map(\.id),
            tracksByID: Dictionary(scopedTracks.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        )
    }

    func fetchAppleScriptLibraryIDsForConfiguredScope() async throws -> [String] {
        try await fetchAppleScriptLibrarySnapshotForConfiguredScope().trackIDs
    }

    func fetchAppleScriptTracks(
        trackIDs: Set<String>,
        scopedTracksByID: [String: Track]?
    ) async throws -> [Track] {
        guard !trackIDs.isEmpty else { return [] }

        if let scopedTracksByID {
            return trackIDs.sorted().compactMap { scopedTracksByID[$0] }
        }

        return try await scriptBridge.fetchTracksByIDs(
            Array(trackIDs),
            batchSize: runtimeConfiguration.idsBatchSize,
            timeout: runtimeConfiguration.idsBatchFetchTimeout
        )
    }

    private func fetchAppleScriptTracksForConfiguredScope() async throws -> [Track]? {
        let testArtists = runtimeConfiguration.testArtists
        guard !testArtists.isEmpty else { return nil }

        var tracks: [Track] = []
        for artist in testArtists {
            let artistTracks = try await scriptBridge.fetchTracks(
                artist: artist,
                timeout: runtimeConfiguration.fullLibraryFetchTimeout
            )
            tracks.append(contentsOf: artistTracks)
        }
        return tracksInConfiguredScope(tracks)
    }
}
