import Core
import DesignUI
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Artist catalog adapter")
struct ArtistCatalogAdapterTests {
    @Test("maps backend entries and normalizes the selected scope")
    func mapsAvailableCatalog() {
        let projection = ArtistCatalogProjection(
            revision: .initial,
            state: .available([ArtistCatalogEntry(name: "In Flames", trackCount: 202)]),
            issue: "The Music catalog may be out of date."
        )

        let scope = ArtistCatalogAdapter.makeScope(
            selected: [" In Flames ", "IN FLAMES"],
            settingsRevision: 12,
            projection: projection
        )

        #expect(scope.settingsRevision == 12)
        #expect(scope.selected == ["In Flames"])
        #expect(scope.options == [DesignArtistOption(name: "In Flames", trackCount: 202)])
        #expect(scope.catalogIssue == "The Music catalog may be out of date.")
    }

    @Test("keeps backend unavailability actionable")
    func mapsUnavailableCatalog() {
        let scope = ArtistCatalogAdapter.makeScope(
            selected: ["Björk"],
            settingsRevision: 14,
            projection: ArtistCatalogProjection(
                revision: .initial,
                state: .unavailable(reason: "Catalog unavailable")
            )
        )

        #expect(scope.selected == ["Björk"])
        #expect(scope.options.isEmpty)
        #expect(scope.catalogIssue == "Catalog unavailable")
    }

    @Test("refresh uses an unscoped live read and updates an open narrowed settings surface")
    @MainActor
    func refreshesFromFullLibrary() async throws {
        var configuration = AppConfiguration()
        configuration.development.testArtists = ["Björk"]
        let catalog = CatalogProbe(tracks: [
            catalogTrack(id: "BJORK-1", title: "Jóga", artist: "Björk", album: "Homogenic"),
            catalogTrack(id: "BJORK-2", title: "Bachelorette", artist: "Björk", album: "Homogenic"),
            catalogTrack(id: "BOOMBOX-1", title: "Вахтерам", artist: "Бумбокс", album: "Меломанія"),
        ])
        let dependencies = AppDependencies(configurationLoader: { configuration }, musicCatalog: catalog)
        let feed = ArtistCatalogFeed()
        let observation = Task { await feed.observe(dependencies.projectionStore) }
        defer { observation.cancel() }

        await dependencies.refreshArtistCatalog()

        try await waitUntil {
            feed.projection.state == .available([
                ArtistCatalogEntry(name: "Björk", trackCount: 2),
                ArtistCatalogEntry(name: "Бумбокс", trackCount: 1),
            ])
        }
        #expect(await catalog.loadCount() == 1)

        await catalog.replaceTracks([
            catalogTrack(id: "BJORK-1", title: "Jóga", artist: "Björk", album: "Homogenic"),
            catalogTrack(id: "BJORK-2", title: "Bachelorette", artist: "Björk", album: "Homogenic"),
            catalogTrack(id: "BOOMBOX-1", title: "Вахтерам", artist: "Бумбокс", album: "Меломанія"),
            catalogTrack(
                id: "IN-FLAMES-1",
                title: "Cloud Connected",
                artist: "In Flames",
                album: "Reroute to Remain"
            ),
        ])
        await dependencies.refreshArtistCatalog()

        try await waitUntil {
            guard case let .available(entries) = feed.projection.state else { return false }
            return entries.map(\.name) == ["Björk", "In Flames", "Бумбокс"]
        }
        #expect(await catalog.loadCount() == 2)
    }

    @Test("cancellation preserves the last available catalog")
    @MainActor
    func keepsCatalogOnCancellation() async throws {
        let catalog = CatalogProbe(tracks: [
            catalogTrack(id: "BJORK-1", title: "Jóga", artist: "Björk", album: "Homogenic"),
        ])
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            musicCatalog: catalog
        )

        await dependencies.refreshArtistCatalog()
        let availableProjection = try await currentArtistCatalog(in: dependencies.projectionStore)
        #expect(availableProjection.state == .available([ArtistCatalogEntry(name: "Björk", trackCount: 1)]))

        await catalog.replaceFailure(.cancellation)
        let outcome = await dependencies.refreshArtistCatalog()
        let projectionAfterCancellation = try await currentArtistCatalog(in: dependencies.projectionStore)

        #expect(outcome == .cancelled)
        #expect(projectionAfterCancellation == availableProjection)
    }

    @Test("a MusicKit failure preserves the last committed physical catalog")
    @MainActor
    func preservesCommittedCatalogAfterFetchFailure() async throws {
        let catalog = CatalogProbe(tracks: [
            catalogTrack(id: "BJORK-1", title: "Jóga", artist: "Björk", album: "Homogenic"),
        ])
        let store = try CatalogDataStore(modelContainer: ModelContainerFactory.createInMemory())
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            musicCatalog: catalog
        )
        dependencies.configureLibraryPersistenceForTesting(catalogStore: store)

        await dependencies.refreshArtistCatalog()
        let committed = try await currentArtistCatalog(in: dependencies.projectionStore)
        #expect(committed.state == .available([ArtistCatalogEntry(name: "Björk", trackCount: 1)]))

        await catalog.replaceTracks([
            catalogTrack(id: "CHER-1", title: "Believe", artist: "Cher", album: "Believe"),
        ])
        await catalog.replaceFailure(.fetchFailed)
        await dependencies.refreshArtistCatalog()

        let afterFailure = try await currentArtistCatalog(in: dependencies.projectionStore)
        let persisted = try #require(try await store.loadSnapshot())
        #expect(afterFailure.state == committed.state)
        #expect(afterFailure.issue == "Couldn’t load artists. Try again.")
        #expect(persisted.tracks.map(\.artist) == ["Björk"])
    }

    @Test(
        "authorization failures publish their actionable localized reason",
        arguments: [CatalogFailure.authorizationDenied, .authorizationRestricted]
    )
    @MainActor
    func showsAuthorizationReasons(failure: CatalogFailure) async throws {
        let catalog = CatalogProbe(tracks: [], failure: failure)
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            musicCatalog: catalog
        )

        await dependencies.refreshArtistCatalog()
        let projection = try await currentArtistCatalog(in: dependencies.projectionStore)

        #expect(projection.state == .unavailable(reason: failure.localizedReason))
    }

    @Test("catalog authorization and count do not require processing permission")
    @MainActor
    func authorizesAndCountsWithoutProcessing() async throws {
        let catalog = CatalogProbe(tracks: [
            catalogTrack(id: "CATALOG-1", title: "Jóga", artist: "Björk", album: "Homogenic"),
        ], isAuthorized: false)
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            musicCatalog: catalog
        )

        try await dependencies.requestCatalogAccess()
        await dependencies.refreshArtistCatalog()
        let count = dependencies.catalogSnapshot?.tracks.count

        #expect(await catalog.authorizationRequests() == 1)
        #expect(count == 1)
        #expect(await catalog.loadCount() == 1)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 100 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The open settings surface did not receive the refreshed artist catalog")
    }

    private func currentArtistCatalog(in store: ProjectionStore) async throws -> ArtistCatalogProjection {
        let stream = await store.artistCatalogUpdates()
        var iterator = stream.makeAsyncIterator()
        return try #require(await iterator.next())
    }
}

actor CatalogProbe: MusicCatalogReading {
    private var tracks: [CatalogTrack]
    private var failure: CatalogFailure
    private var loads = 0
    private var authorizationRequestCount = 0
    private var isAuthorizationGranted: Bool
    private var shouldBlockNextLoad = false
    private var didStartBlockedLoad = false
    private var blockedLoadWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedLoadRelease: CheckedContinuation<Void, Never>?

    init(
        tracks: [CatalogTrack],
        isAuthorized: Bool = true,
        failure: CatalogFailure = .none
    ) {
        self.tracks = tracks
        self.failure = failure
        isAuthorizationGranted = isAuthorized
    }

    var isAuthorized: Bool {
        isAuthorizationGranted
    }

    func requestAuthorization() async throws {
        authorizationRequestCount += 1
        isAuthorizationGranted = true
    }

    func loadCatalog() async throws -> CatalogSnapshot {
        loads += 1
        let snapshot = CatalogSnapshot(tracks: tracks)
        if shouldBlockNextLoad {
            shouldBlockNextLoad = false
            didStartBlockedLoad = true
            blockedLoadWaiters.forEach { $0.resume() }
            blockedLoadWaiters.removeAll()
            await withCheckedContinuation { blockedLoadRelease = $0 }
        }
        switch failure {
        case .none:
            break
        case .cancellation:
            throw CancellationError()
        case .authorizationDenied:
            throw MusicLibraryError.authorizationDenied
        case .authorizationRestricted:
            throw MusicLibraryError.authorizationRestricted
        case .fetchFailed:
            throw MusicLibraryError.fetchFailed(detail: "fixture failure")
        }
        return snapshot
    }

    func replaceTracks(_ tracks: [CatalogTrack]) {
        self.tracks = tracks
    }

    func replaceFailure(_ failure: CatalogFailure) {
        self.failure = failure
    }

    func loadCount() -> Int {
        loads
    }

    func blockNextLoad() {
        shouldBlockNextLoad = true
        didStartBlockedLoad = false
    }

    func waitUntilBlockedLoadStarts() async {
        guard !didStartBlockedLoad else { return }
        await withCheckedContinuation { blockedLoadWaiters.append($0) }
    }

    func releaseBlockedLoad() {
        blockedLoadRelease?.resume()
        blockedLoadRelease = nil
    }

    func authorizationRequests() -> Int {
        authorizationRequestCount
    }
}

enum CatalogFailure: Sendable {
    case none
    case cancellation
    case authorizationDenied
    case authorizationRestricted
    case fetchFailed

    var localizedReason: String {
        switch self {
        case .authorizationDenied:
            MusicLibraryError.authorizationDenied.localizedDescription
        case .authorizationRestricted:
            MusicLibraryError.authorizationRestricted.localizedDescription
        case .none, .cancellation, .fetchFailed:
            preconditionFailure("The selected failure has no catalog issue")
        }
    }
}

func catalogTrack(id: String, title: String, artist: String, album: String) -> CatalogTrack {
    guard let catalogID = CatalogTrackID(displayValue: id) else {
        preconditionFailure("Invalid catalog ID")
    }
    return CatalogTrack(
        id: catalogID,
        title: title,
        artist: artist,
        album: album,
        albumArtist: nil,
        genres: [],
        dates: CatalogDates(releaseYear: nil, dateAdded: nil)
    )
}
