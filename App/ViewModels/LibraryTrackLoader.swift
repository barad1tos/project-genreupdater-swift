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
    let isMutationMetadataReady: Bool
    let scanDate: Date
}

@MainActor
enum LibraryTrackLoader {
    static func scopedArtists(from dependencies: AppDependencies) -> [String] {
        ArtistAllowList.normalized(dependencies.config.development.testArtists)
    }

    static func liveReader(from dependencies: AppDependencies) -> MusicLibraryReader? {
        dependencies.musicReader
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
        from dependencies: AppDependencies,
        reader: MusicLibraryReader,
        scopedArtists: [String]
    ) async throws -> LibraryLiveTrackLoad {
        try Task.checkCancellation()
        try await reader.requestAuthorization()
        try Task.checkCancellation()
        await reader.updateTestArtists(scopedArtists)
        let liveTracks = try await reader.fetchAllTracks()
        try Task.checkCancellation()
        let isMappingReady = await dependencies.refreshTrackIDMapping(musicKitTracks: liveTracks)
        try Task.checkCancellation()

        return LibraryLiveTrackLoad(
            tracks: liveTracks,
            isMutationMetadataReady: isMappingReady,
            scanDate: .now
        )
    }
}
