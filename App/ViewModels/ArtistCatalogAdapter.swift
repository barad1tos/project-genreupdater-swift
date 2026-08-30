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
            issue = projection.issue
        case let .unavailable(reason):
            options = []
            issue = projection.issue ?? reason
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
    func refreshArtistCatalog(republishBrowse: Bool = true) async {
        let token = catalogLoadGate.begin()
        let generation = await projectionStore.claimArtistCatalogGeneration()
        guard catalogLoadGate.isCurrent(token) else { return }
        guard let result = await loadArtistCatalog(token: token) else { return }

        guard catalogLoadGate.isCurrent(token) else { return }
        catalogSnapshot = result.snapshot
        catalogSnapshotSource = result.source
        catalogLoadIssue = result.issue
        await projectionStore.replaceArtistCatalog(result.projection, inputGeneration: generation)
        guard catalogLoadGate.isCurrent(token) else { return }
        await refreshChromeProjection()
        guard catalogLoadGate.isCurrent(token) else { return }
        if republishBrowse {
            await applyBrowseTruth?(browseProcessingFacts, nil)
        }
    }

    private func loadArtistCatalog(token: UInt64) async -> ArtistCatalogRefreshResult? {
        do {
            let snapshot = try await musicCatalog.loadCatalog()
            guard catalogLoadGate.isCurrent(token) else { return nil }
            try await catalogStore?.replaceSnapshot(snapshot)
            guard catalogLoadGate.isCurrent(token) else { return nil }
            return ArtistCatalogRefreshResult(
                snapshot: snapshot,
                source: .live,
                issue: nil,
                projection: ArtistCatalogBuilder.makeProjection(tracks: snapshot.tracks)
            )
        } catch is CancellationError {
            return nil
        } catch let error as MusicLibraryError {
            return await resultForMusicLibraryError(error)
        } catch {
            artistCatalogLog.error(
                "Artist catalog refresh failed with an unexpected error: \(error.localizedDescription, privacy: .private)"
            )
            return await preservedArtistCatalog(or: "Couldn’t load artists. Try again.")
        }
    }

    private func resultForMusicLibraryError(_ error: MusicLibraryError) async -> ArtistCatalogRefreshResult {
        switch error {
        case .authorizationDenied, .authorizationRestricted:
            return await preservedArtistCatalog(or: error.localizedDescription)
        case let .fetchFailed(detail):
            artistCatalogLog.error("Artist catalog refresh failed during MusicKit fetch: \(detail, privacy: .private)")
            return await preservedArtistCatalog(or: "Couldn’t load artists. Try again.")
        case .musicAppNotAvailable:
            artistCatalogLog.error("Artist catalog refresh failed because Music is unavailable")
            return await preservedArtistCatalog(or: "Open Music, then try again.")
        }
    }

    private func unavailableArtistCatalog(reason: String) -> ArtistCatalogProjection {
        ArtistCatalogProjection(revision: .initial, state: .unavailable(reason: reason))
    }

    private func preservedArtistCatalog(or unavailableReason: String) async -> ArtistCatalogRefreshResult {
        if let catalogSnapshot {
            return ArtistCatalogRefreshResult(
                snapshot: catalogSnapshot,
                source: catalogSnapshotSource,
                issue: unavailableReason,
                projection: ArtistCatalogBuilder.makeProjection(
                    tracks: catalogSnapshot.tracks,
                    issue: unavailableReason
                )
            )
        }
        do {
            if let snapshot = try await catalogStore?.loadSnapshot() {
                return ArtistCatalogRefreshResult(
                    snapshot: snapshot,
                    source: .persisted,
                    issue: unavailableReason,
                    projection: ArtistCatalogBuilder.makeProjection(
                        tracks: snapshot.tracks,
                        issue: unavailableReason
                    )
                )
            }
        } catch {
            artistCatalogLog.error(
                "Persisted artist catalog recovery failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        return ArtistCatalogRefreshResult(
            snapshot: nil,
            source: nil,
            issue: unavailableReason,
            projection: unavailableArtistCatalog(reason: unavailableReason)
        )
    }
}

private struct ArtistCatalogRefreshResult {
    let snapshot: CatalogSnapshot?
    let source: CatalogSnapshotSource?
    let issue: String?
    let projection: ArtistCatalogProjection
}
