import Core
import Foundation
import Testing
@testable import Genre_Updater

@Suite("Update track scope resolver")
struct ScopeResolverTests {
    @Test("workflow scope is the loaded library")
    func workflowScopeIsTheLoadedLibrary() {
        let tracks = makeTracks()

        let resolved = UpdateTrackScopeResolver.tracksForWorkflow(libraryTracks: tracks)

        #expect(resolved.map(\.id) == ["one", "two", "three"])
    }

    @Test("workflow scope applies the test artist allow-list")
    func workflowScopeAppliesTestArtistAllowList() {
        let tracks = makeTracks()

        let resolved = UpdateTrackScopeResolver.tracksForWorkflow(
            libraryTracks: tracks,
            testArtists: ["Beta"]
        )

        #expect(resolved.map(\.id) == ["three"])
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

    @Test("incremental scope applies genre mappings when detecting mismatches")
    func mappingMismatch() {
        let track = Track(
            id: "mapped",
            name: "Mapped Genre",
            artist: "Artist",
            album: "Album",
            genre: "Electronic",
            dateAdded: Date(timeIntervalSince1970: 500)
        )

        let resolved = UpdateTrackScopeResolver.incrementalTracks(
            [track],
            lastRunTime: Date(timeIntervalSince1970: 1000),
            options: IncrementalTrackScopeOptions(
                updateGenre: true,
                genreMappings: ["Electronic": "Electronica"]
            )
        )

        #expect(resolved.map(\.id) == ["mapped"])
    }

    @Test("incremental scope groups explicit feature credits")
    func featureCreditMismatch() {
        let source = Track(
            id: "source",
            name: "Source",
            artist: "Artist",
            album: "Earlier",
            genre: "Rock",
            dateAdded: Date(timeIntervalSince1970: 100)
        )
        let target = Track(
            id: "target",
            name: "Target",
            artist: "Artist feat. Guest",
            album: "Later",
            genre: "Jazz",
            dateAdded: Date(timeIntervalSince1970: 500)
        )

        let resolved = UpdateTrackScopeResolver.incrementalTracks(
            [source, target],
            lastRunTime: Date(timeIntervalSince1970: 1000)
        )

        #expect(resolved.map(\.id) == ["target"])
    }

    @Test("incremental scope keeps unavailable tracks as evidence only")
    func readOnlyIsNotTarget() {
        let editableEvidence = Track(
            id: "editable-evidence",
            name: "Editable Evidence",
            artist: "Artist",
            album: "Earlier",
            genre: "Rock",
            dateAdded: Date(timeIntervalSince1970: 100)
        )
        let unavailableMismatch = Track(
            id: "unavailable-mismatch",
            name: "Unavailable Mismatch",
            artist: "Artist",
            album: "Later",
            genre: "Jazz",
            dateAdded: Date(timeIntervalSince1970: 500),
            trackStatus: TrackKind.noLongerAvailable.rawValue
        )

        let resolved = UpdateTrackScopeResolver.incrementalTracks(
            [editableEvidence, unavailableMismatch],
            lastRunTime: Date(timeIntervalSince1970: 1000)
        )

        #expect(resolved.isEmpty)
    }

    @Test("incremental scope does not split artist names containing and")
    func preservesAndInArtist() {
        let bandTrack = Track(
            id: "band",
            name: "Band Track",
            artist: "Florence and the Machine",
            album: "Album",
            genre: "Rock",
            dateAdded: Date(timeIntervalSince1970: 100)
        )
        let soloTrack = Track(
            id: "solo",
            name: "Solo Track",
            artist: "Florence",
            album: "Album",
            genre: "Jazz",
            dateAdded: Date(timeIntervalSince1970: 500)
        )

        let resolved = UpdateTrackScopeResolver.incrementalTracks(
            [bandTrack, soloTrack],
            lastRunTime: Date(timeIntervalSince1970: 1000)
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

    @Test("incremental scope includes tracks changed since previous snapshot")
    func incrementalScopeIncludesTracksChangedSincePreviousSnapshot() {
        let lastRunTime = Date(timeIntervalSince1970: 1000)

        let resolved = UpdateTrackScopeResolver.incrementalTracks(
            makeSnapshotChangedTracks(),
            lastRunTime: lastRunTime,
            previousTracks: makePreviousSnapshotTracks(),
            options: IncrementalTrackScopeOptions(updateGenre: false)
        )

        #expect(resolved.map(\.id) == ["status-changed", "genre-changed", "year-changed"])
    }

    @Test("incremental scope ignores status changes without a stored status")
    func incrementalScopeIgnoresStatusChangesWithoutStoredStatus() {
        let resolved = UpdateTrackScopeResolver.incrementalTracks(
            [
                Track(
                    id: "new-status-only",
                    name: "New Status Only",
                    artist: "Alpha",
                    album: "First",
                    genre: "Rock",
                    year: 2001,
                    dateAdded: Date(timeIntervalSince1970: 500),
                    trackStatus: "subscription"
                ),
            ],
            lastRunTime: Date(timeIntervalSince1970: 1000),
            previousTracks: [
                Track(
                    id: "new-status-only",
                    name: "New Status Only",
                    artist: "Alpha",
                    album: "First",
                    genre: "Rock",
                    year: 2001,
                    dateAdded: Date(timeIntervalSince1970: 500),
                    trackStatus: nil
                ),
            ],
            options: IncrementalTrackScopeOptions(updateGenre: false)
        )

        #expect(resolved.isEmpty)
    }

    private func makeSnapshotChangedTracks() -> [Track] {
        [
            Track(
                id: "status-changed",
                name: "Status Changed",
                artist: "Alpha",
                album: "First",
                genre: "Rock",
                year: 2001,
                dateAdded: Date(timeIntervalSince1970: 500),
                trackStatus: "subscription"
            ),
            Track(
                id: "genre-changed",
                name: "Genre Changed",
                artist: "Beta",
                album: "Second",
                genre: "Pop",
                year: 2002,
                dateAdded: Date(timeIntervalSince1970: 500),
                trackStatus: "purchased"
            ),
            Track(
                id: "year-changed",
                name: "Year Changed",
                artist: "Gamma",
                album: "Third",
                genre: "Jazz",
                year: 2003,
                dateAdded: Date(timeIntervalSince1970: 500),
                trackStatus: "purchased"
            ),
        ]
    }

    private func makePreviousSnapshotTracks() -> [Track] {
        [
            Track(
                id: "status-changed",
                name: "Status Changed",
                artist: "Alpha",
                album: "First",
                genre: "Rock",
                year: 2001,
                dateAdded: Date(timeIntervalSince1970: 500),
                trackStatus: "prerelease"
            ),
            Track(
                id: "genre-changed",
                name: "Genre Changed",
                artist: "Beta",
                album: "Second",
                genre: "Rock",
                year: 2002,
                dateAdded: Date(timeIntervalSince1970: 500),
                trackStatus: "purchased"
            ),
            Track(
                id: "year-changed",
                name: "Year Changed",
                artist: "Gamma",
                album: "Third",
                genre: "Jazz",
                year: 1999,
                dateAdded: Date(timeIntervalSince1970: 500),
                trackStatus: "purchased"
            ),
        ]
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
