import Core
import Foundation
import Services

struct LibraryCachedTrackLoad {
    let tracks: [Track]

    var hasTracks: Bool {
        !tracks.isEmpty
    }
}

struct LibraryLiveTrackLoad {
    let tracks: [Track]
    let isLibraryReadyForUpdates: Bool
    let scanDate: Date
}

@MainActor
enum LibraryTrackLoader {
    static func scopedArtists(from dependencies: AppDependencies) -> [String] {
        ArtistAllowList.normalized(dependencies.config.development.testArtists)
    }

    static func liveProvider(from dependencies: AppDependencies) -> (any LibraryReadProvider)? {
        dependencies.libraryReadProvider
    }

    static func cachedSnapshot(
        from dependencies: AppDependencies,
        scopedArtists: [String],
        forceRefresh: Bool
    ) async -> LibraryCachedTrackLoad? {
        guard !forceRefresh, let cachedTracks = await dependencies.loadLibrarySnapshot() else {
            return nil
        }

        let scopedCachedTracks = UpdateTrackScopeResolver.filteredByTestArtists(
            cachedTracks,
            testArtists: scopedArtists
        )
        return LibraryCachedTrackLoad(tracks: scopedCachedTracks)
    }

    static func liveTracks(
        provider: any LibraryReadProvider,
        scopedArtists: [String]
    ) async throws -> LibraryLiveTrackLoad {
        try Task.checkCancellation()
        let snapshot = try await provider.loadLibrarySnapshot(request: LibraryReadRequest(
            testArtists: scopedArtists
        ))
        try Task.checkCancellation()

        return LibraryLiveTrackLoad(
            tracks: snapshot.tracks,
            isLibraryReadyForUpdates: true,
            scanDate: snapshot.scannedAt
        )
    }
}
