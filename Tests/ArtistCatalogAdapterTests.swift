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
            projection: projection
        )

        #expect(scope.selected == ["In Flames"])
        #expect(scope.options == [DesignArtistOption(name: "In Flames", trackCount: 202)])
        #expect(scope.catalogIssue == nil)
    }

    @Test("keeps backend unavailability actionable")
    func mapsUnavailableCatalog() {
        let scope = ArtistCatalogAdapter.makeScope(
            selected: ["Björk"],
            projection: ArtistCatalogProjection(
                revision: .initial,
                state: .unavailable(reason: "Mirror unavailable")
            )
        )

        #expect(scope.selected == ["Björk"])
        #expect(scope.options.isEmpty)
        #expect(scope.catalogIssue == "Mirror unavailable")
    }
}
