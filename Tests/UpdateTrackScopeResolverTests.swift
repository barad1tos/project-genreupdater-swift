import Core
import Foundation
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

    @Test("incremental scope without last run processes all tracks")
    func incrementalScopeWithoutLastRunProcessesAllTracks() {
        let tracks = makeIncrementalTracks()

        let resolved = UpdateTrackScopeResolver.incrementalTracks(tracks, lastRunTime: nil)

        #expect(resolved.map(\.id) == ["old-complete", "new-complete", "old-missing", "old-unknown"])
    }

    @Test("incremental scope keeps new tracks and tracks with missing genres")
    func incrementalScopeKeepsNewTracksAndTracksWithMissingGenres() {
        let tracks = makeIncrementalTracks()
        let lastRunTime = Date(timeIntervalSince1970: 1000)

        let resolved = UpdateTrackScopeResolver.incrementalTracks(tracks, lastRunTime: lastRunTime)

        #expect(resolved.map(\.id) == ["new-complete", "old-missing", "old-unknown"])
    }

    @Test("incremental scope includes existing genre mismatches when genre updates are enabled")
    func incrementalScopeIncludesGenreMismatchesWhenGenreUpdatesAreEnabled() {
        let tracks = makeGenreMismatchTracks()
        let lastRunTime = Date(timeIntervalSince1970: 1000)

        let resolved = UpdateTrackScopeResolver.incrementalTracks(
            tracks,
            lastRunTime: lastRunTime,
            options: IncrementalTrackScopeOptions(updateGenre: true)
        )

        #expect(resolved.map(\.id) == ["old-mismatch"])
    }

    @Test("incremental scope skips existing genre mismatches when genre updates are disabled")
    func incrementalScopeSkipsGenreMismatchesWhenGenreUpdatesAreDisabled() {
        let tracks = makeGenreMismatchTracks()
        let lastRunTime = Date(timeIntervalSince1970: 1000)

        let resolved = UpdateTrackScopeResolver.incrementalTracks(
            tracks,
            lastRunTime: lastRunTime,
            options: IncrementalTrackScopeOptions(updateGenre: false)
        )

        #expect(resolved.isEmpty)
    }

    @Test("incremental scope deduplicates new tracks that also have missing genres")
    func incrementalScopeDeduplicatesNewTracksWithMissingGenres() {
        let lastRunTime = Date(timeIntervalSince1970: 1000)
        let tracks = [
            Track(
                id: "new-missing",
                name: "New Missing",
                artist: "Alpha",
                album: "First",
                genre: nil,
                dateAdded: Date(timeIntervalSince1970: 2000)
            ),
            Track(
                id: "old-missing",
                name: "Old Missing",
                artist: "Alpha",
                album: "First",
                genre: " ",
                dateAdded: Date(timeIntervalSince1970: 500)
            ),
        ]

        let resolved = UpdateTrackScopeResolver.incrementalTracks(tracks, lastRunTime: lastRunTime)

        #expect(resolved.map(\.id) == ["new-missing", "old-missing"])
    }

    private func makeTracks() -> [Track] {
        [
            Track(id: "one", name: "One", artist: "Alpha", album: "First"),
            Track(id: "two", name: "Two", artist: "Alpha", album: "First"),
            Track(id: "three", name: "Three", artist: "Beta", album: "Second"),
        ]
    }

    private func makeIncrementalTracks() -> [Track] {
        [
            Track(
                id: "old-complete",
                name: "Old Complete",
                artist: "Alpha",
                album: "First",
                genre: "Rock",
                dateAdded: Date(timeIntervalSince1970: 500)
            ),
            Track(
                id: "new-complete",
                name: "New Complete",
                artist: "Alpha",
                album: "First",
                genre: "Rock",
                dateAdded: Date(timeIntervalSince1970: 2000)
            ),
            Track(
                id: "old-missing",
                name: "Old Missing",
                artist: "Alpha",
                album: "First",
                genre: nil,
                dateAdded: Date(timeIntervalSince1970: 500)
            ),
            Track(
                id: "old-unknown",
                name: "Old Unknown",
                artist: "Beta",
                album: "Second",
                genre: " unknown ",
                dateAdded: Date(timeIntervalSince1970: 500)
            ),
        ]
    }

    private func makeGenreMismatchTracks() -> [Track] {
        [
            Track(
                id: "dominant-source",
                name: "First",
                artist: "Alpha",
                album: "First Album",
                genre: "Rock",
                dateAdded: Date(timeIntervalSince1970: 100)
            ),
            Track(
                id: "old-mismatch",
                name: "Second",
                artist: "Alpha",
                album: "Second Album",
                genre: "Pop",
                dateAdded: Date(timeIntervalSince1970: 500)
            ),
            Track(
                id: "old-match",
                name: "Third",
                artist: "Alpha",
                album: "Third Album",
                genre: "Rock",
                dateAdded: Date(timeIntervalSince1970: 700)
            ),
        ]
    }
}
