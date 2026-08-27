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

    static func cachedSnapshot(
        from dependencies: AppDependencies,
        scopedArtists: [String],
        forceRefresh: Bool
    ) async -> [Track]? {
        guard !forceRefresh, let cachedTracks = await dependencies.loadLibrarySnapshot() else {
            return nil
        }

        guard let scopedCachedTracks = try? canonicalTracks(cachedTracks, scopedArtists: scopedArtists) else {
            return nil
        }
        return scopedCachedTracks
    }

    static func currentMirror(
        store: any TrackStateStore,
        cachedTracks: [Track] = [],
        requirement: MirrorRequirement,
        at date: Date = Date()
    ) async throws -> LibraryMirrorTrackLoad {
        try Task.checkCancellation()
        let snapshot = try await store.loadMirrorSnapshot()
        try Task.checkCancellation()
        let readiness = snapshot.readiness(for: requirement, at: date)
        let tracks = try presentationTracks(
            snapshot: snapshot,
            cachedTracks: cachedTracks,
            scopedArtists: requirement.normalizedTestArtists
        )

        return LibraryMirrorTrackLoad(
            tracks: tracks,
            readiness: readiness
        )
    }

    private static func presentationTracks(
        snapshot: TrackMirrorSnapshot,
        cachedTracks: [Track],
        scopedArtists: [String]
    ) throws -> [Track] {
        var tracks = try canonicalTracks(snapshot.presentTracks, scopedArtists: scopedArtists)
        var includedIDs = Set(tracks.compactMap(\.databaseID))
        for track in try canonicalTracks(cachedTracks, scopedArtists: scopedArtists) {
            guard let databaseID = track.databaseID,
                  snapshot.presentIDs.contains(databaseID),
                  includedIDs.insert(databaseID).inserted
            else { continue }
            tracks.append(track)
        }
        return tracks
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
