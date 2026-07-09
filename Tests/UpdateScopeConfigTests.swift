import Core
import Foundation
import Testing
@testable import Genre_Updater

@Suite("Selected update scope configuration")
@MainActor
struct UpdateScopeConfigTests {
    @Test("genres action updates only genres")
    func genresActionUpdatesOnlyGenres() {
        let configuration = makeConfiguration(action: .genres)

        #expect(configuration.updateGenre)
        #expect(!configuration.updateYear)
        #expect(!configuration.previewOnly)
        #expect(configuration.tracks.map(\.id) == ["1"])
    }

    @Test("years action updates only years")
    func yearsActionUpdatesOnlyYears() {
        let configuration = makeConfiguration(action: .years)

        #expect(!configuration.updateGenre)
        #expect(configuration.updateYear)
        #expect(!configuration.previewOnly)
    }

    @Test("dry run action preserves default update selection and forces preview")
    func dryRunActionPreservesDefaultsAndForcesPreview() {
        let configuration = SelectedUpdateScopeConfiguration(
            tracks: makeTracks(),
            action: .dryRun,
            defaultUpdateGenre: false,
            defaultUpdateYear: true,
            defaultPreviewOnly: false
        )

        #expect(!configuration.updateGenre)
        #expect(configuration.updateYear)
        #expect(configuration.previewOnly)
    }

    @Test("browse request maps selected typed items into update scope")
    func browseRequestMapsSelectedTypedItemsIntoUpdateScope() throws {
        let browseViewModel = BrowseViewModel()
        browseViewModel.tracks = [
            Track(id: "1", name: "One", artist: "Alpha", album: "First"),
            Track(id: "2", name: "Two", artist: "Alpha", album: "First"),
            Track(id: "3", name: "Three", artist: "Beta", album: "Second"),
        ]
        let albumID = AlbumSummary.makeID(artist: "Alpha", name: "First")
        let notification = Notification(
            name: .browseAction,
            userInfo: [
                BrowseUpdateAction.actionUserInfoKey: BrowseUpdateAction.years.rawValue,
                BrowseUpdateAction.selectedItemsUserInfoKey: Set([BrowseSelectionItem.albumID(albumID)]),
            ]
        )
        let request = try #require(BrowseUpdateRequest(notification: notification))

        let configuration = SelectedUpdateScopeConfiguration(
            request: request,
            browseViewModel: browseViewModel,
            defaultUpdateGenre: true,
            defaultUpdateYear: true,
            defaultPreviewOnly: false
        )

        #expect(configuration.tracks.map(\.id) == ["1", "2"])
        #expect(!configuration.updateGenre)
        #expect(configuration.updateYear)
        #expect(!configuration.previewOnly)
    }

    private func makeConfiguration(action: BrowseUpdateAction) -> SelectedUpdateScopeConfiguration {
        SelectedUpdateScopeConfiguration(
            tracks: makeTracks(),
            action: action,
            defaultUpdateGenre: true,
            defaultUpdateYear: true,
            defaultPreviewOnly: false
        )
    }

    private func makeTracks() -> [Track] {
        [Track(id: "1", name: "One", artist: "Alpha", album: "First")]
    }
}
