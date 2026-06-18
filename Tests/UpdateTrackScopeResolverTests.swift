import Core
import Testing
@testable import Genre_Updater

@Suite("Update track scope resolver")
struct UpdateTrackScopeResolverTests {
    @Test("selected tracks mode uses the selected scope")
    func selectedTracksModeUsesSelectedScope() {
        let tracks = makeTracks()
        let selectedScope = [tracks[1]]

        let resolved = UpdateTrackScopeResolver.tracksForWorkflow(
            libraryTracks: tracks,
            selectedScopeTracks: selectedScope,
            mode: .selectedTracks
        )

        #expect(resolved.map(\.id) == ["two"])
    }

    @Test("selected tracks mode without selected scope stays empty")
    func selectedTracksModeWithoutSelectedScopeStaysEmpty() {
        let tracks = makeTracks()

        let resolved = UpdateTrackScopeResolver.tracksForWorkflow(
            libraryTracks: tracks,
            selectedScopeTracks: nil,
            mode: .selectedTracks
        )

        #expect(resolved.isEmpty)
    }

    @Test("full library mode ignores stale selected scope")
    func fullLibraryModeIgnoresStaleSelectedScope() {
        let tracks = makeTracks()
        let selectedScope = [tracks[1]]

        let resolved = UpdateTrackScopeResolver.tracksForWorkflow(
            libraryTracks: tracks,
            selectedScopeTracks: selectedScope,
            mode: .fullLibrary
        )

        #expect(resolved.map(\.id) == ["one", "two", "three"])
    }

    @Test("full library mode applies test artist allow-list")
    func fullLibraryModeAppliesTestArtistAllowList() {
        let tracks = makeTracks()

        let resolved = UpdateTrackScopeResolver.tracksForWorkflow(
            libraryTracks: tracks,
            selectedScopeTracks: nil,
            mode: .fullLibrary,
            testArtists: ["Beta"]
        )

        #expect(resolved.map(\.id) == ["three"])
    }

    @Test("selected tracks mode applies test artist allow-list")
    func selectedTracksModeAppliesTestArtistAllowList() {
        let tracks = makeTracks()
        let selectedScope = [tracks[0], tracks[2]]

        let resolved = UpdateTrackScopeResolver.tracksForWorkflow(
            libraryTracks: tracks,
            selectedScopeTracks: selectedScope,
            mode: .selectedTracks,
            testArtists: ["Beta"]
        )

        #expect(resolved.map(\.id) == ["three"])
    }

    @Test("reconcile selected scope rebases to loaded library tracks")
    func reconcileSelectedScopeRebasesToLoadedLibraryTracks() {
        let oldScope = [
            Track(id: "two", name: "Old Two", artist: "Alpha", album: "Old"),
            Track(id: "missing", name: "Missing", artist: "Alpha", album: "Old"),
        ]
        let loadedTracks = makeTracks()

        let reconciled = UpdateTrackScopeResolver.reconciledSelectedScope(
            currentScopeTracks: oldScope,
            libraryTracks: loadedTracks
        )

        #expect(reconciled?.map(\.name) == ["Two"])
    }

    @Test("reconcile selected scope applies test artist allow-list")
    func reconcileSelectedScopeAppliesTestArtistAllowList() {
        let oldScope = [
            Track(id: "two", name: "Old Two", artist: "Alpha", album: "Old"),
            Track(id: "three", name: "Old Three", artist: "Beta", album: "Old"),
        ]
        let loadedTracks = makeTracks()

        let reconciled = UpdateTrackScopeResolver.reconciledSelectedScope(
            currentScopeTracks: oldScope,
            libraryTracks: loadedTracks,
            testArtists: ["Beta"]
        )

        #expect(reconciled?.map(\.name) == ["Three"])
    }

    private func makeTracks() -> [Track] {
        [
            Track(id: "one", name: "One", artist: "Alpha", album: "First"),
            Track(id: "two", name: "Two", artist: "Alpha", album: "First"),
            Track(id: "three", name: "Three", artist: "Beta", album: "Second"),
        ]
    }
}
