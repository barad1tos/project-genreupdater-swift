import Testing
@testable import DesignUI

@Suite("Test artist scope draft")
struct ArtistScopeTests {
    @Test("toggles artists case-insensitively and exposes full-library selection")
    func togglesSelection() {
        var draft = ArtistScopeDraft(selected: ["In Flames", "IN FLAMES", "  "])

        #expect(draft.selected == ["In Flames"])
        #expect(!draft.hasChanges(comparedTo: ["IN FLAMES"]))

        draft.toggle("Metallica")
        #expect(draft.contains("metallica"))
        #expect(!draft.isFullLibrary)
        #expect(draft.hasChanges(comparedTo: ["In Flames"]))

        draft.toggle("IN FLAMES")
        draft.toggle("METALLICA")
        #expect(draft.selected.isEmpty)
        #expect(draft.isFullLibrary)
    }

    @Test("filters the full catalog with localized user-facing search")
    func filtersCatalog() {
        let scope = DesignArtistScope(
            selected: ["In Flames"],
            options: [
                DesignArtistOption(name: "Björk", trackCount: 42),
                DesignArtistOption(name: "In Flames", trackCount: 202),
                DesignArtistOption(name: "Metallica", trackCount: 180),
            ]
        )

        #expect(scope.options(matching: "flam").map(\.name) == ["In Flames"])
        #expect(scope.options(matching: "bjork").map(\.name) == ["Björk"])
        #expect(scope.options(matching: "  ").count == 3)
    }

    @Test("settings snapshot carries one coherent artist scope")
    func settingsCarriesScope() {
        let scope = DesignArtistScope(
            selected: ["In Flames"],
            options: [DesignArtistOption(name: "In Flames", trackCount: 202)]
        )

        let settings = DesignSettingsSnapshot(
            updateBehavior: .both,
            minimumConfidencePercent: 90,
            releaseYearRestoreThresholdYears: 5,
            artistScope: scope,
            isPostWriteVerificationRequired: true
        )

        #expect(settings.artistScope == scope)
    }
}
