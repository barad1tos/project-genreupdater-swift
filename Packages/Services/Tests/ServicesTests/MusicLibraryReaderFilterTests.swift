import Testing
@testable import Core
@testable import Services

// MARK: - Helpers

private func makeTrack(
    id: String,
    artist: String,
    albumArtist: String? = nil
) -> Track {
    Track(
        id: id,
        name: "Song",
        artist: artist,
        album: "Album",
        albumArtist: albumArtist
    )
}

// MARK: - Tests

@Suite("MusicLibraryReader — testArtists filtering")
struct MusicLibraryReaderFilterTests {
    private let library = [
        makeTrack(id: "1", artist: "Beatles"),
        makeTrack(id: "2", artist: "Queen"),
        makeTrack(id: "3", artist: "Pink Floyd"),
        makeTrack(id: "4", artist: "Led Zeppelin"),
    ]

    @Test("Empty testArtists returns all tracks unfiltered")
    func emptyTestArtistsPassesAll() {
        let result = MusicLibraryReader.filterByTestArtists(
            library,
            testArtists: []
        )
        #expect(result.count == library.count)
    }

    @Test("Single testArtist filters to matching tracks only")
    func singleArtistFilter() {
        let result = MusicLibraryReader.filterByTestArtists(
            library,
            testArtists: ["Beatles"]
        )
        #expect(result.count == 1)
        #expect(result.first?.artist == "Beatles")
    }

    @Test("Filtering is case-insensitive")
    func caseInsensitiveMatch() {
        let result = MusicLibraryReader.filterByTestArtists(
            library,
            testArtists: ["beatles"]
        )
        #expect(result.count == 1)
        #expect(result.first?.artist == "Beatles")
    }

    @Test("Multiple testArtists returns tracks from all listed artists")
    func multipleArtistFilter() {
        let result = MusicLibraryReader.filterByTestArtists(
            library,
            testArtists: ["Beatles", "Queen"]
        )
        #expect(result.count == 2)
        let artists = Set(result.map(\.artist))
        #expect(artists == ["Beatles", "Queen"])
    }

    @Test("Filtering uses effectiveArtist (prefers albumArtist)")
    func usesEffectiveArtist() {
        let tracks = [
            makeTrack(
                id: "10",
                artist: "John Lennon",
                albumArtist: "Beatles"
            ),
            makeTrack(id: "11", artist: "Queen"),
        ]
        let result = MusicLibraryReader.filterByTestArtists(
            tracks,
            testArtists: ["Beatles"]
        )
        #expect(result.count == 1)
        #expect(result.first?.id == "10")
    }

    @Test("No matching artists returns empty array")
    func noMatchReturnsEmpty() {
        let result = MusicLibraryReader.filterByTestArtists(
            library,
            testArtists: ["Radiohead"]
        )
        #expect(result.isEmpty)
    }

    @Test("Test artists create artist-scoped fetch targets")
    func artistsCreateArtistScopedFetchTargets() {
        let targets = MusicLibraryReader.fetchTargets(
            requestedArtist: nil,
            testArtists: [" In Flames ", "Metallica", "in flames"],
            ignoreTestFilter: false
        )

        #expect(targets == ["In Flames", "Metallica"])
    }

    @Test("Empty test artists keep full-library fetch target")
    func emptyTestArtistsKeepFullLibraryFetchTarget() {
        let targets = MusicLibraryReader.fetchTargets(
            requestedArtist: nil,
            testArtists: [],
            ignoreTestFilter: false
        )

        #expect(targets == [nil])
    }

    @Test("Explicit artist fetch is preserved when test filtering is ignored")
    func explicitArtistFetchIsPreservedWhenTestFilteringIsIgnored() {
        let targets = MusicLibraryReader.fetchTargets(
            requestedArtist: "Massive Attack",
            testArtists: ["In Flames"],
            ignoreTestFilter: true
        )

        #expect(targets == ["Massive Attack"])
    }
}
