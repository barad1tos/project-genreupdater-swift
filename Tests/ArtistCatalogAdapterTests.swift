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
            state: .available([ArtistCatalogEntry(name: "In Flames", trackCount: 202)])
        )

        let scope = ArtistCatalogAdapter.makeScope(
            selected: [" In Flames ", "IN FLAMES"],
            settingsRevision: 12,
            projection: projection
        )

        #expect(scope.settingsRevision == 12)
        #expect(scope.selected == ["In Flames"])
        #expect(scope.options == [DesignArtistOption(name: "In Flames", trackCount: 202)])
        #expect(scope.catalogIssue == nil)
    }

    @Test("keeps backend unavailability actionable")
    func mapsUnavailableCatalog() {
        let scope = ArtistCatalogAdapter.makeScope(
            selected: ["Björk"],
            settingsRevision: 14,
            projection: ArtistCatalogProjection(
                revision: .initial,
                state: .unavailable(reason: "Mirror unavailable")
            )
        )

        #expect(scope.selected == ["Björk"])
        #expect(scope.options.isEmpty)
        #expect(scope.catalogIssue == "Mirror unavailable")
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
        #expect(await catalog.capturedScopes() == [[]])

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
        #expect(await catalog.capturedScopes() == [[], []])
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
        await dependencies.refreshArtistCatalog()
        let projectionAfterCancellation = try await currentArtistCatalog(in: dependencies.projectionStore)

        #expect(projectionAfterCancellation == availableProjection)
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
        let count = await dependencies.probedPhysicalTrackCount()

        #expect(await catalog.authorizationRequests() == 1)
        #expect(count == 1)
        #expect(await catalog.capturedScopes().isEmpty)
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

private actor CatalogProbe: MusicCatalogReading {
    private var tracks: [CatalogTrack]
    private var failure: CatalogFailure
    private var scopes: [[String]] = []
    private var authorizationRequestCount = 0
    private var isAuthorizationGranted: Bool

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

    func loadCatalog(testArtists: [String]) async throws -> CatalogSnapshot {
        scopes.append(testArtists)
        switch failure {
        case .none:
            break
        case .cancellation:
            throw CancellationError()
        case .authorizationDenied:
            throw MusicLibraryError.authorizationDenied
        case .authorizationRestricted:
            throw MusicLibraryError.authorizationRestricted
        }
        return CatalogSnapshot(tracks: tracks)
    }

    func trackCount() async throws -> Int {
        tracks.count
    }

    func replaceTracks(_ tracks: [CatalogTrack]) {
        self.tracks = tracks
    }

    func replaceFailure(_ failure: CatalogFailure) {
        self.failure = failure
    }

    func capturedScopes() -> [[String]] {
        scopes
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

    var localizedReason: String {
        switch self {
        case .authorizationDenied:
            MusicLibraryError.authorizationDenied.localizedDescription
        case .authorizationRestricted:
            MusicLibraryError.authorizationRestricted.localizedDescription
        case .none, .cancellation:
            preconditionFailure("The selected failure has no catalog issue")
        }
    }
}

private func catalogTrack(id: String, title: String, artist: String, album: String) -> CatalogTrack {
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
        releaseYear: nil,
        dateAdded: nil
    )
}
