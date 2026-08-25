import Core
import Foundation
import Services

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
    ) async throws -> LibraryCachedTrackLoad? {
        guard !forceRefresh, let cachedTracks = await dependencies.loadLibrarySnapshot() else {
            return nil
        }

        let scopedCachedTracks = try canonicalTracks(cachedTracks, scopedArtists: scopedArtists)
        return LibraryCachedTrackLoad(tracks: scopedCachedTracks)
    }

    static func currentMirror(
        store: any TrackStateStore,
        scopedArtists: [String]
    ) async throws -> LibraryMirrorTrackLoad {
        try Task.checkCancellation()
        let tracks = try await store.loadAllTracks()
        try Task.checkCancellation()

        return try LibraryMirrorTrackLoad(
            tracks: canonicalTracks(tracks, scopedArtists: scopedArtists),
            isLibraryReadyForUpdates: true
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
