import Core
import DesignUI
import Observation
import Services

@MainActor
@Observable
final class ArtistCatalogFeed {
    private(set) var projection: ArtistCatalogProjection = .empty()

    func observe(_ store: ProjectionStore) async {
        for await projection in await store.artistCatalogUpdates() {
            self.projection = projection
        }
    }
}

enum ArtistCatalogAdapter {
    static func makeScope(
        selected: [String],
        settingsRevision: UInt64,
        projection: ArtistCatalogProjection
    ) -> DesignArtistScope {
        let options: [DesignArtistOption]
        let issue: String?

        switch projection.state {
        case let .available(entries):
            options = entries.map { DesignArtistOption(name: $0.name, trackCount: $0.trackCount) }
            issue = nil
        case let .unavailable(reason):
            options = []
            issue = reason
        }

        return DesignArtistScope(
            settingsRevision: settingsRevision,
            selected: ArtistAllowList.normalized(selected),
            options: options,
            catalogIssue: issue
        )
    }
}

extension AppDependencies {
    func refreshArtistCatalog() async -> ArtistCatalogProjection {
        let generation = await projectionStore.claimArtistCatalogGeneration()
        let projection: ArtistCatalogProjection
        let provider = LibraryTrackLoader.liveProvider(from: self)

        do {
            let tracks: [Core.Track]
            if let provider {
                tracks = try await provider.loadLibrarySnapshot(request: LibraryReadRequest()).tracks
            } else if let trackStore {
                tracks = try await trackStore.loadAllTracks()
            } else {
                return await projectionStore.replaceArtistCatalog(
                    .init(
                        revision: .initial,
                        state: .unavailable(reason: "Artist catalog isn’t ready yet.")
                    ),
                    inputGeneration: generation
                )
            }
            projection = ArtistCatalogBuilder.makeProjection(tracks: tracks)
        } catch {
            projection = .init(
                revision: .initial,
                state: .unavailable(reason: "Couldn’t load artists from the full music library.")
            )
        }

        return await projectionStore.replaceArtistCatalog(projection, inputGeneration: generation)
    }
}
