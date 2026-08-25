import Core
import DesignUI
import Foundation
import Observation
import Services

private let artistCatalogLog = AppLogger.make(category: "artist-catalog")

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
    func refreshArtistCatalog() async {
        let generation = await projectionStore.claimArtistCatalogGeneration()
        let projection: ArtistCatalogProjection
        do {
            let snapshot = try await musicCatalog.loadCatalog(testArtists: [])
            projection = ArtistCatalogBuilder.makeProjection(tracks: snapshot.tracks)
        } catch is CancellationError {
            return
        } catch let error as MusicLibraryError {
            switch error {
            case .authorizationDenied, .authorizationRestricted:
                projection = unavailableArtistCatalog(reason: error.localizedDescription)
            case let .fetchFailed(detail):
                artistCatalogLog
                    .error("Artist catalog refresh failed during MusicKit fetch: \(detail, privacy: .private)")
                projection = unavailableArtistCatalog(reason: "Couldn’t load artists. Try again.")
            case .musicAppNotAvailable:
                artistCatalogLog.error("Artist catalog refresh failed because Music is unavailable")
                projection = unavailableArtistCatalog(reason: "Open Music, then try again.")
            }
        } catch {
            artistCatalogLog.error(
                "Artist catalog refresh failed with an unexpected error: \(error.localizedDescription, privacy: .private)"
            )
            projection = unavailableArtistCatalog(reason: "Couldn’t load artists. Try again.")
        }

        await projectionStore.replaceArtistCatalog(projection, inputGeneration: generation)
    }

    private func unavailableArtistCatalog(reason: String) -> ArtistCatalogProjection {
        ArtistCatalogProjection(revision: .initial, state: .unavailable(reason: reason))
    }
}
