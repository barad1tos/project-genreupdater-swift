import Core
import Foundation

struct LibraryMirrorTrackLoad {
    let tracks: [Track]
    let readiness: MirrorReadiness
}

@MainActor
enum LibraryTrackLoader {
    static func scopedArtists(from dependencies: AppDependencies) -> [String] {
        ArtistAllowList.normalized(dependencies.config.development.testArtists)
    }

    /// Rebuildable historical presentation used only for incremental comparison.
    /// It never contributes current rows or processing readiness.
    static func previousSnapshot(
        from dependencies: AppDependencies,
        scopedArtists: [String],
        forceRefresh: Bool
    ) async -> [Track]? {
        guard !forceRefresh, let cachedTracks = await dependencies.loadLibrarySnapshot() else {
            return nil
        }
        return try? canonicalTracks(cachedTracks, scopedArtists: scopedArtists)
    }

    static func currentMirror(
        store: any TrackStateStore,
        requirement: MirrorRequirement,
        at date: Date = Date()
    ) async throws -> LibraryMirrorTrackLoad {
        try Task.checkCancellation()
        let snapshot = try await store.loadMirrorSnapshot()
        try Task.checkCancellation()
        let readiness = snapshot.readiness(for: requirement, at: date)
        let tracks = try canonicalTracks(
            snapshot.presentTracks,
            scopedArtists: requirement.normalizedTestArtists
        )

        return LibraryMirrorTrackLoad(
            tracks: tracks,
            readiness: readiness
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
