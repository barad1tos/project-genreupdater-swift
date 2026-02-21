import Testing
import Foundation
@testable import Core

// MARK: - GenreDeterminator Tests

@Suite("GenreDeterminator — Dominant Genre from Earliest Album")
struct GenreDeterminatorTests {

    let determinator = GenreDeterminator()

    // MARK: - Helpers

    /// Create a date from components for readable tests.
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 0
        components.minute = 0
        components.second = 0
        components.timeZone = TimeZone(identifier: "UTC")
        // swiftlint:disable:next force_unwrapping
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    /// Create a track with minimal required fields.
    private func makeTrack(
        id: String = "1",
        name: String = "Track",
        artist: String = "Artist",
        album: String = "Album",
        genre: String? = "Rock",
        dateAdded: Date? = nil
    ) -> Track {
        Track(
            id: id,
            name: name,
            artist: artist,
            album: album,
            genre: genre,
            dateAdded: dateAdded
        )
    }

    // MARK: - Empty / No Tracks

    @Test("Empty array returns nil genre")
    func emptyArray() {
        let result = determinator.determineDominantGenre(artistTracks: [])
        #expect(result.genre == nil)
        #expect(result.sourceAlbum == nil)
        #expect(result.sourceTrackDateAdded == nil)
    }

    // MARK: - Single Track

    @Test("Single track with genre and dateAdded returns its genre")
    func singleTrack() {
        let track = makeTrack(
            album: "OK Computer",
            genre: "Alternative",
            dateAdded: date(2020, 1, 15)
        )
        let result = determinator.determineDominantGenre(artistTracks: [track])
        #expect(result.genre == "Alternative")
        #expect(result.sourceAlbum == "OK Computer")
        #expect(result.sourceTrackDateAdded == date(2020, 1, 15))
    }

    @Test("Single track without dateAdded returns nil genre")
    func singleTrackNoDate() {
        let track = makeTrack(genre: "Rock", dateAdded: nil)
        let result = determinator.determineDominantGenre(artistTracks: [track])
        #expect(result.genre == nil)
    }

    @Test("Single track with empty album returns nil genre")
    func singleTrackEmptyAlbum() {
        let track = makeTrack(album: "", genre: "Rock", dateAdded: date(2020, 1, 1))
        let result = determinator.determineDominantGenre(artistTracks: [track])
        #expect(result.genre == nil)
    }

    // MARK: - Multiple Albums — Earliest Wins

    @Test("Multiple albums — genre from earliest album wins")
    func multipleAlbumsEarliestWins() {
        let tracks = [
            makeTrack(id: "1", album: "Album B", genre: "Jazz", dateAdded: date(2022, 6, 1)),
            makeTrack(id: "2", album: "Album A", genre: "Rock", dateAdded: date(2020, 1, 1)),
            makeTrack(id: "3", album: "Album C", genre: "Pop", dateAdded: date(2023, 3, 15)),
        ]
        let result = determinator.determineDominantGenre(artistTracks: tracks)
        #expect(result.genre == "Rock")
        #expect(result.sourceAlbum == "Album A")
    }

    @Test("Two albums same date — deterministic result")
    func twoAlbumsSameDate() {
        // When dates are equal, the first one encountered stays (no replacement on ==)
        let tracks = [
            makeTrack(id: "1", album: "Alpha", genre: "Rock", dateAdded: date(2020, 1, 1)),
            makeTrack(id: "2", album: "Beta", genre: "Jazz", dateAdded: date(2020, 1, 1)),
        ]
        let result = determinator.determineDominantGenre(artistTracks: tracks)
        // Both have same date, one of them wins. genre should be non-nil.
        #expect(result.genre != nil)
        #expect(result.genre == "Rock" || result.genre == "Jazz")
    }

    // MARK: - Multiple Tracks Per Album — Earliest Track

    @Test("Multiple tracks in same album — earliest track's genre used")
    func multipleTracksInSameAlbum() {
        let tracks = [
            makeTrack(id: "1", album: "Album X", genre: "Pop", dateAdded: date(2020, 6, 15)),
            makeTrack(id: "2", album: "Album X", genre: "Rock", dateAdded: date(2020, 1, 1)),
            makeTrack(id: "3", album: "Album X", genre: "Jazz", dateAdded: date(2020, 12, 31)),
        ]
        let result = determinator.determineDominantGenre(artistTracks: tracks)
        #expect(result.genre == "Rock")
        #expect(result.sourceAlbum == "Album X")
        #expect(result.sourceTrackDateAdded == date(2020, 1, 1))
    }

    // MARK: - Tracks Without dateAdded — Skipped

    @Test("Tracks without dateAdded are skipped")
    func tracksWithoutDateSkipped() {
        let tracks = [
            makeTrack(id: "1", album: "Album A", genre: "Electronic", dateAdded: nil),
            makeTrack(id: "2", album: "Album B", genre: "Rock", dateAdded: date(2021, 5, 10)),
        ]
        let result = determinator.determineDominantGenre(artistTracks: tracks)
        #expect(result.genre == "Rock")
        #expect(result.sourceAlbum == "Album B")
    }

    @Test("All tracks without dateAdded returns nil")
    func allTracksNoDate() {
        let tracks = [
            makeTrack(id: "1", album: "A", genre: "Rock", dateAdded: nil),
            makeTrack(id: "2", album: "B", genre: "Pop", dateAdded: nil),
        ]
        let result = determinator.determineDominantGenre(artistTracks: tracks)
        #expect(result.genre == nil)
    }

    // MARK: - Empty Album Names — Skipped

    @Test("Tracks with empty album name are skipped")
    func emptyAlbumSkipped() {
        let tracks = [
            makeTrack(id: "1", album: "", genre: "Electronic", dateAdded: date(2019, 1, 1)),
            makeTrack(id: "2", album: "Real Album", genre: "Metal", dateAdded: date(2020, 1, 1)),
        ]
        let result = determinator.determineDominantGenre(artistTracks: tracks)
        #expect(result.genre == "Metal")
        #expect(result.sourceAlbum == "Real Album")
    }

    @Test("All tracks with empty album returns nil")
    func allEmptyAlbum() {
        let tracks = [
            makeTrack(id: "1", album: "", genre: "Rock", dateAdded: date(2020, 1, 1)),
            makeTrack(id: "2", album: "", genre: "Pop", dateAdded: date(2021, 1, 1)),
        ]
        let result = determinator.determineDominantGenre(artistTracks: tracks)
        #expect(result.genre == nil)
    }

    // MARK: - Empty / Nil Genre → nil

    @Test("Track with nil genre returns nil")
    func nilGenreReturnsNil() {
        let track = makeTrack(genre: nil, dateAdded: date(2020, 1, 1))
        let result = determinator.determineDominantGenre(artistTracks: [track])
        #expect(result.genre == nil)
        #expect(result.sourceAlbum == nil)
    }

    @Test("Track with empty genre returns nil")
    func emptyGenreReturnsNil() {
        let track = makeTrack(genre: "", dateAdded: date(2020, 1, 1))
        let result = determinator.determineDominantGenre(artistTracks: [track])
        #expect(result.genre == nil)
        #expect(result.sourceAlbum == nil)
    }

    // MARK: - Genre Returned As-Is (No Normalization)

    @Test("Genre is returned as-is without normalization")
    func genreReturnedAsIs() {
        let track = makeTrack(genre: "post-punk revival", dateAdded: date(2020, 1, 1))
        let result = determinator.determineDominantGenre(artistTracks: [track])
        #expect(result.genre == "post-punk revival")
    }

    @Test("Genre with unusual casing preserved")
    func genreCasingPreserved() {
        let track = makeTrack(genre: "HEAVY METAL", dateAdded: date(2020, 1, 1))
        let result = determinator.determineDominantGenre(artistTracks: [track])
        #expect(result.genre == "HEAVY METAL")
    }

    // MARK: - Mixed Valid and Invalid Tracks

    @Test("Mix of valid and invalid tracks — valid earliest wins")
    func mixValidInvalid() {
        let tracks = [
            makeTrack(id: "1", album: "", genre: "Ignored", dateAdded: date(2018, 1, 1)),
            makeTrack(id: "2", album: "A", genre: "NoDate", dateAdded: nil),
            makeTrack(id: "3", album: "B", genre: "Winner", dateAdded: date(2019, 6, 1)),
            makeTrack(id: "4", album: "C", genre: "Later", dateAdded: date(2022, 1, 1)),
        ]
        let result = determinator.determineDominantGenre(artistTracks: tracks)
        #expect(result.genre == "Winner")
        #expect(result.sourceAlbum == "B")
    }

    // MARK: - Realistic Scenario

    @Test("Realistic artist library — Beatles-like scenario")
    func realisticScenario() {
        let tracks = [
            // Please Please Me (1963 album, added 2015)
            makeTrack(id: "1", name: "I Saw Her Standing There", artist: "The Beatles",
                      album: "Please Please Me", genre: "Pop", dateAdded: date(2015, 3, 20)),
            makeTrack(id: "2", name: "Love Me Do", artist: "The Beatles",
                      album: "Please Please Me", genre: "Pop", dateAdded: date(2015, 3, 20)),

            // Abbey Road (1969 album, added 2016)
            makeTrack(id: "3", name: "Come Together", artist: "The Beatles",
                      album: "Abbey Road", genre: "Rock", dateAdded: date(2016, 8, 1)),
            makeTrack(id: "4", name: "Here Comes the Sun", artist: "The Beatles",
                      album: "Abbey Road", genre: "Rock", dateAdded: date(2016, 8, 5)),

            // Let It Be (1970 album, added 2017)
            makeTrack(id: "5", name: "Let It Be", artist: "The Beatles",
                      album: "Let It Be", genre: "Rock", dateAdded: date(2017, 1, 10)),
        ]
        let result = determinator.determineDominantGenre(artistTracks: tracks)
        // Earliest album by dateAdded: Please Please Me (2015-03-20)
        #expect(result.genre == "Pop")
        #expect(result.sourceAlbum == "Please Please Me")
    }

    // MARK: - Performance Sanity

    @Test("Large track array completes quickly")
    func largeArrayPerformance() {
        var tracks: [Track] = []
        for i in 0..<10_000 {
            let albumIndex = i / 10
            tracks.append(makeTrack(
                id: "\(i)",
                album: "Album \(albumIndex)",
                genre: "Genre \(albumIndex)",
                dateAdded: date(2000 + (albumIndex % 25), (i % 12) + 1, (i % 28) + 1)
            ))
        }

        let result = determinator.determineDominantGenre(artistTracks: tracks)
        #expect(result.genre != nil)
    }

    // MARK: - Same Album Different Genres

    @Test("Same album, tracks with different genres — earliest track's genre wins")
    func sameAlbumDifferentGenres() {
        let tracks = [
            makeTrack(id: "1", album: "Hybrid Theory", genre: "Nu Metal", dateAdded: date(2020, 6, 1)),
            makeTrack(id: "2", album: "Hybrid Theory", genre: "Alternative", dateAdded: date(2020, 1, 1)),
            makeTrack(id: "3", album: "Hybrid Theory", genre: "Rock", dateAdded: date(2020, 12, 1)),
        ]
        let result = determinator.determineDominantGenre(artistTracks: tracks)
        #expect(result.genre == "Alternative")
    }

    // MARK: - Source Info in Result

    @Test("Result includes source album and date")
    func resultIncludesSourceInfo() {
        let expectedDate = date(2019, 7, 4)
        let track = makeTrack(
            album: "Disintegration",
            genre: "Post-Punk",
            dateAdded: expectedDate
        )
        let result = determinator.determineDominantGenre(artistTracks: [track])
        #expect(result.sourceAlbum == "Disintegration")
        #expect(result.sourceTrackDateAdded == expectedDate)
    }
}

// MARK: - Genre Mapping Tests

@Suite("GenreDeterminator — Custom Genre Mappings")
struct GenreMappingTests {

    let determinator = GenreDeterminator()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 0
        components.minute = 0
        components.second = 0
        components.timeZone = TimeZone(identifier: "UTC")
        // swiftlint:disable:next force_unwrapping
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    private func makeTrack(
        id: String = "1",
        name: String = "Track",
        artist: String = "Artist",
        album: String = "Album",
        genre: String? = "Rock",
        dateAdded: Date? = nil
    ) -> Track {
        Track(
            id: id,
            name: name,
            artist: artist,
            album: album,
            genre: genre,
            dateAdded: dateAdded
        )
    }

    // MARK: - determineDominantGenre with Mappings

    @Test("Genre mapping replaces matching genre")
    func genreMappingReplaces() {
        let track = makeTrack(genre: "Electronica", dateAdded: date(2020, 1, 1))
        let mappings = ["Electronica": "Electronic"]
        let result = determinator.determineDominantGenre(
            artistTracks: [track],
            genreMappings: mappings
        )
        #expect(result.genre == "Electronic")
    }

    @Test("Genre mapping is case-insensitive on lookup")
    func genreMappingCaseInsensitive() {
        let track = makeTrack(genre: "hip hop", dateAdded: date(2020, 1, 1))
        let mappings = ["Hip Hop": "Hip-Hop"]
        let result = determinator.determineDominantGenre(
            artistTracks: [track],
            genreMappings: mappings
        )
        #expect(result.genre == "Hip-Hop")
    }

    @Test("Genre mapping preserves target case from dictionary")
    func genreMappingPreservesTargetCase() {
        let track = makeTrack(genre: "ELECTRONICA", dateAdded: date(2020, 1, 1))
        let mappings = ["electronica": "Electronic Dance Music"]
        let result = determinator.determineDominantGenre(
            artistTracks: [track],
            genreMappings: mappings
        )
        #expect(result.genre == "Electronic Dance Music")
    }

    @Test("Genre mapping with no match returns original genre")
    func genreMappingNoMatch() {
        let track = makeTrack(genre: "Metal", dateAdded: date(2020, 1, 1))
        let mappings = ["Electronica": "Electronic"]
        let result = determinator.determineDominantGenre(
            artistTracks: [track],
            genreMappings: mappings
        )
        #expect(result.genre == "Metal")
    }

    @Test("Genre mapping with empty dictionary returns original genre")
    func genreMappingEmptyDict() {
        let track = makeTrack(genre: "Rock", dateAdded: date(2020, 1, 1))
        let result = determinator.determineDominantGenre(
            artistTracks: [track],
            genreMappings: [:]
        )
        #expect(result.genre == "Rock")
    }

    @Test("Genre mapping does not apply when genre is nil")
    func genreMappingNilGenre() {
        let track = makeTrack(genre: nil, dateAdded: date(2020, 1, 1))
        let mappings = ["Rock": "Alternative"]
        let result = determinator.determineDominantGenre(
            artistTracks: [track],
            genreMappings: mappings
        )
        #expect(result.genre == nil)
    }

    @Test("No-arg overload behaves identically to empty mappings")
    func noArgOverloadSameAsEmpty() {
        let track = makeTrack(genre: "Jazz", dateAdded: date(2020, 1, 1))
        let resultNoArg = determinator.determineDominantGenre(artistTracks: [track])
        let resultEmpty = determinator.determineDominantGenre(
            artistTracks: [track],
            genreMappings: [:]
        )
        #expect(resultNoArg == resultEmpty)
    }

    // MARK: - applyGenreMapping (Static Helper)

    @Test("applyGenreMapping exact match returns mapped value")
    func applyGenreMappingExact() {
        let result = GenreDeterminator.applyGenreMapping(
            "Electronica",
            mappings: ["Electronica": "Electronic"]
        )
        #expect(result == "Electronic")
    }

    @Test("applyGenreMapping case-insensitive match")
    func applyGenreMappingCaseInsensitive() {
        let result = GenreDeterminator.applyGenreMapping(
            "hip hop",
            mappings: ["Hip Hop": "Hip-Hop"]
        )
        #expect(result == "Hip-Hop")
    }

    @Test("applyGenreMapping no match returns original")
    func applyGenreMappingNoMatch() {
        let result = GenreDeterminator.applyGenreMapping(
            "Metal",
            mappings: ["Rock": "Alternative"]
        )
        #expect(result == "Metal")
    }

    @Test("applyGenreMapping empty mappings returns original")
    func applyGenreMappingEmpty() {
        let result = GenreDeterminator.applyGenreMapping("Rock", mappings: [:])
        #expect(result == "Rock")
    }
}
