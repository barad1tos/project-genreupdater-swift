import Testing
@testable import DesignUI

@Suite("Test artist scope draft")
struct ArtistScopeTests {
    @Test("cancel leaves the staged scope untouched and apply commits once")
    func stagesChangesUntilApply() {
        var flow = ArtistScopeFlow(scope: makeScope())
        var appliedChanges: [ArtistScopeChange] = []

        #expect(flow.cancel() == .dismiss)
        #expect(appliedChanges.isEmpty)

        flow.toggle("Metallica")
        let action = flow.requestApply { change in
            appliedChanges.append(change)
            return .accepted
        }

        #expect(action == .dismiss)
        #expect(appliedChanges == [ArtistScopeChange(
            selected: ["In Flames", "Metallica"],
            expectedSettingsRevision: 42
        )])
    }

    @Test("full-library confirmation protects scope and stale saves stay open")
    func confirmsFullLibraryAndKeepsStaleDraft() {
        var flow = ArtistScopeFlow(scope: makeScope())
        var applyCount = 0

        flow.toggle("IN FLAMES")
        let requestAction = flow.requestApply { _ in
            applyCount += 1
            return .accepted
        }

        #expect(requestAction == .none)
        #expect(flow.isFullScopePromptOpen)
        #expect(applyCount == 0)

        flow.cancelFullLibrary()
        #expect(!flow.isFullScopePromptOpen)
        #expect(applyCount == 0)

        _ = flow.requestApply { _ in .accepted }
        let staleAction = flow.confirmFullLibrary { _ in
            applyCount += 1
            return .stale
        }

        #expect(staleAction == .none)
        #expect(!flow.isFullScopePromptOpen)
        #expect(applyCount == 1)
        #expect(flow.saveIssue == "Settings changed elsewhere. Cancel and reopen to review the current selection.")

        var failedFlow = ArtistScopeFlow(scope: makeScope())
        failedFlow.toggle("IN FLAMES")
        _ = failedFlow.requestApply { _ in .accepted }
        let failedAction = failedFlow.confirmFullLibrary { _ in .failed }

        #expect(failedAction == .none)
        #expect(failedFlow.saveIssue == "Couldn’t save this scope. Your previous selection is unchanged.")
    }

    @Test("toggles artists case-insensitively and exposes full-library selection")
    func togglesSelection() {
        var draft = ArtistScopeDraft(
            selected: ["In Flames", "IN FLAMES", "  "],
            settingsRevision: 42
        )

        #expect(draft.selected == ["In Flames"])
        #expect(!draft.hasChanges)

        draft.toggle("Metallica")
        #expect(draft.contains("metallica"))
        #expect(!draft.isFullLibrary)
        #expect(draft.hasChanges)

        #expect(draft.change == ArtistScopeChange(
            selected: ["In Flames", "Metallica"],
            expectedSettingsRevision: 42
        ))

        draft.toggle("IN FLAMES")
        draft.toggle("METALLICA")
        #expect(draft.selected.isEmpty)
        #expect(draft.isFullLibrary)
    }

    @Test("filters the full catalog with localized user-facing search")
    func filtersCatalog() {
        let scope = DesignArtistScope(
            settingsRevision: 7,
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
            settingsRevision: 7,
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

    private func makeScope() -> DesignArtistScope {
        DesignArtistScope(
            settingsRevision: 42,
            selected: ["In Flames"],
            options: [
                DesignArtistOption(name: "In Flames", trackCount: 202),
                DesignArtistOption(name: "Metallica", trackCount: 180),
            ]
        )
    }
}
