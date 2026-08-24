import Core
import DesignUI
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

    @Test("refresh uses the full mirror and updates an open narrowed settings surface")
    @MainActor
    func refreshesFromFullMirror() async throws {
        var configuration = AppConfiguration()
        configuration.development.testArtists = ["Björk"]
        let trackStore = try TrackDataStore.createInMemory()
        try await trackStore.initialize()
        try await trackStore.saveTracks([
            Core.Track(id: "BJORK-1", name: "Jóga", artist: "Björk", album: "Homogenic"),
            Core.Track(id: "BJORK-2", name: "Bachelorette", artist: "Björk", album: "Homogenic"),
            Core.Track(id: "BOOMBOX-1", name: "Вахтерам", artist: "Бумбокс", album: "Меломанія"),
        ])
        let dependencies = AppDependencies(configurationLoader: { configuration })
        dependencies.configureLibraryPersistenceForTesting(trackStore: trackStore)
        let feed = ArtistCatalogFeed()
        let observation = Task { await feed.observe(dependencies.projectionStore) }
        defer { observation.cancel() }

        _ = await dependencies.refreshArtistCatalog()

        try await waitUntil {
            feed.projection.state == .available([
                ArtistCatalogEntry(name: "Björk", trackCount: 2),
                ArtistCatalogEntry(name: "Бумбокс", trackCount: 1),
            ])
        }

        try await trackStore.saveTracks([
            Core.Track(id: "IN-FLAMES-1", name: "Cloud Connected", artist: "In Flames", album: "Reroute to Remain")
        ])
        _ = await dependencies.refreshArtistCatalog()

        try await waitUntil {
            guard case let .available(entries) = feed.projection.state else { return false }
            return entries.map(\.name) == ["Björk", "In Flames", "Бумбокс"]
        }
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
}
