import Core
import Testing
@testable import Genre_Updater

@Suite("Selected update scope configuration")
struct SelectedUpdateScopeConfigurationTests {
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
