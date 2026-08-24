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

    @Test("an open settings surface receives a refreshed artist catalog")
    @MainActor
    func observesCatalogRefresh() async throws {
        let store = ProjectionStore()
        let feed = ArtistCatalogFeed()
        let observation = Task { await feed.observe(store) }
        defer { observation.cancel() }

        _ = await store.replaceArtistCatalog(
            ArtistCatalogProjection(
                revision: .initial,
                state: .available([ArtistCatalogEntry(name: "Бумбокс", trackCount: 31)])
            )
        )

        try await waitUntil {
            feed.projection.state == .available([ArtistCatalogEntry(name: "Бумбокс", trackCount: 31)])
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
