import Core
import DesignUI
import Foundation
import Observation
import Services

private let artistCatalogLog = AppLogger.make(category: "artist-catalog")
private let catalogPersistenceIssue = "Artists are current, but couldn’t be saved for the next launch."
private let catalogRecoveryIssue = "Couldn’t refresh the Music catalog or load its saved snapshot."

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

enum CatalogRefreshOutcome: Equatable {
    case applied
    case superseded
    case cancelled
}

extension AppDependencies {
    @discardableResult
    func refreshArtistCatalog(republishBrowse: Bool = true) async -> CatalogRefreshOutcome {
        let token = catalogLoadGate.begin()
        let generation = await projectionStore.claimArtistCatalogGeneration()
        guard catalogLoadGate.isCurrent(token) else { return .superseded }

        let loadOutcome = await loadArtistCatalog(token: token)
        let result: ArtistCatalogRefreshResult
        switch loadOutcome {
        case let .loaded(loadedResult):
            result = loadedResult
        case .superseded:
            return .superseded
        case .cancelled:
            return .cancelled
        }

        guard catalogLoadGate.isCurrent(token) else { return .superseded }
        catalogSnapshot = result.snapshot
        catalogSnapshotSource = result.source
        catalogIssue = result.issue
        await projectionStore.replaceArtistCatalog(result.projection, inputGeneration: generation)
        guard catalogLoadGate.isCurrent(token) else { return .superseded }
        await refreshChromeProjection()
        guard catalogLoadGate.isCurrent(token) else { return .superseded }
        if republishBrowse {
            await applyBrowseTruth?(browseProcessingFacts, nil)
        }
        return .applied
    }

    private func loadArtistCatalog(token: UInt64) async -> CatalogLoadOutcome {
        do {
            let snapshot = try await musicCatalog.loadCatalog()
            guard catalogLoadGate.isCurrent(token) else { return .superseded }
            let persistenceIssue = try await persistLiveCatalog(snapshot)
            guard !Task.isCancelled else { return .cancelled }
            guard catalogLoadGate.isCurrent(token) else { return .superseded }
            return .loaded(ArtistCatalogRefreshResult(
                snapshot: snapshot,
                source: .live,
                issue: persistenceIssue,
                projection: ArtistCatalogBuilder.makeProjection(
                    tracks: snapshot.tracks,
                    issue: persistenceIssue?.message
                )
            ))
        } catch is CancellationError {
            return .cancelled
        } catch let error as CatalogValidationError {
            artistCatalogLog.error(
                "Live artist catalog validation failed: \(error.localizedDescription, privacy: .private)"
            )
            return await preservedArtistCatalog(or: .refreshFailed(
                message: "Couldn’t validate the Music catalog. Try again."
            ))
        } catch let error as MusicLibraryError {
            return await resultForMusicLibraryError(error)
        } catch {
            artistCatalogLog.error(
                "Artist catalog refresh failed with an unexpected error: \(error.localizedDescription, privacy: .private)"
            )
            return await preservedArtistCatalog(or: .refreshFailed(
                message: "Couldn’t load artists. Try again."
            ))
        }
    }

    private func persistLiveCatalog(_ snapshot: CatalogSnapshot) async throws -> CatalogIssue? {
        do {
            try await catalogStore?.replaceSnapshot(snapshot)
            return nil
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CatalogValidationError {
            throw error
        } catch {
            artistCatalogLog.error(
                "Fresh artist catalog persistence failed: \(error.localizedDescription, privacy: .private)"
            )
            return .persistenceFailed(message: catalogPersistenceIssue)
        }
    }

    private func resultForMusicLibraryError(_ error: MusicLibraryError) async -> CatalogLoadOutcome {
        switch error {
        case .authorizationDenied, .authorizationRestricted:
            return await preservedArtistCatalog(or: .refreshFailed(message: error.localizedDescription))
        case let .fetchFailed(detail):
            artistCatalogLog.error("Artist catalog refresh failed during MusicKit fetch: \(detail, privacy: .private)")
            return await preservedArtistCatalog(or: .refreshFailed(message: "Couldn’t load artists. Try again."))
        case .musicAppNotAvailable:
            artistCatalogLog.error("Artist catalog refresh failed because Music is unavailable")
            return await preservedArtistCatalog(or: .refreshFailed(message: "Open Music, then try again."))
        }
    }

    private func unavailableArtistCatalog(reason: String) -> ArtistCatalogProjection {
        ArtistCatalogProjection(revision: .initial, state: .unavailable(reason: reason))
    }

    private func preservedArtistCatalog(or issue: CatalogIssue) async -> CatalogLoadOutcome {
        guard !Task.isCancelled else { return .cancelled }
        if let catalogSnapshot {
            return .loaded(ArtistCatalogRefreshResult(
                snapshot: catalogSnapshot,
                source: catalogSnapshotSource,
                issue: issue,
                projection: ArtistCatalogBuilder.makeProjection(
                    tracks: catalogSnapshot.tracks,
                    issue: issue.message
                )
            ))
        }
        do {
            if let snapshot = try await catalogStore?.loadSnapshot() {
                return .loaded(ArtistCatalogRefreshResult(
                    snapshot: snapshot,
                    source: .persisted,
                    issue: issue,
                    projection: ArtistCatalogBuilder.makeProjection(
                        tracks: snapshot.tracks,
                        issue: issue.message
                    )
                ))
            }
        } catch is CancellationError {
            return .cancelled
        } catch {
            artistCatalogLog.error(
                "Persisted artist catalog recovery failed: \(error.localizedDescription, privacy: .private)"
            )
            return unavailableCatalog(issue: .recoveryFailed(message: catalogRecoveryIssue))
        }
        return unavailableCatalog(issue: issue)
    }

    private func unavailableCatalog(issue: CatalogIssue) -> CatalogLoadOutcome {
        .loaded(ArtistCatalogRefreshResult(
            snapshot: nil,
            source: nil,
            issue: issue,
            projection: unavailableArtistCatalog(reason: issue.message)
        ))
    }
}

private enum CatalogLoadOutcome {
    case loaded(ArtistCatalogRefreshResult)
    case superseded
    case cancelled
}

private struct ArtistCatalogRefreshResult {
    let snapshot: CatalogSnapshot?
    let source: CatalogSnapshotSource?
    let issue: CatalogIssue?
    let projection: ArtistCatalogProjection
}
