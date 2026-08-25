import Core
import Foundation

struct LibraryCachedTrackLoad {
    let tracks: [Track]

    var hasTracks: Bool {
        !tracks.isEmpty
    }
}

struct LibraryMirrorTrackLoad {
    let tracks: [Track]
    let isLibraryReadyForUpdates: Bool
}

@MainActor
enum LibraryTrackLoader {
    static func scopedArtists(from dependencies: AppDependencies) -> [String] {
        ArtistAllowList.normalized(dependencies.config.development.testArtists)
    }

    static func cachedSnapshot(
        from dependencies: AppDependencies,
        scopedArtists: [String],
        forceRefresh: Bool
    ) async -> LibraryCachedTrackLoad? {
        guard !forceRefresh, let cachedTracks = await dependencies.loadLibrarySnapshot() else {
            return nil
        }

        guard let scopedCachedTracks = try? canonicalTracks(cachedTracks, scopedArtists: scopedArtists) else {
            return nil
        }
        return LibraryCachedTrackLoad(tracks: scopedCachedTracks)
    }

    static func currentMirror(
        store: any TrackStateStore,
        scopedArtists: [String]
    ) async throws -> LibraryMirrorTrackLoad {
        try Task.checkCancellation()
        let snapshot = try await store.loadMirrorSnapshot()
        try Task.checkCancellation()

        return try LibraryMirrorTrackLoad(
            tracks: canonicalTracks(snapshot.tracks, scopedArtists: scopedArtists),
            isLibraryReadyForUpdates: snapshot.isSeeded
        )
    }

    private static func canonicalTracks(_ tracks: [Track], scopedArtists: [String]) throws -> [Track] {
        for track in tracks {
            guard let databaseID = track.databaseID, track.id == databaseID.rawValue else {
                throw LibraryLoadError.nonCanonicalMirror(trackID: track.id)
            }
        }
        return ArtistAllowList.filter(tracks, allowedArtists: scopedArtists)
    }
}
