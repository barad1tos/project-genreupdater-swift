import Testing
@testable import Core

@Suite("YearDeterminator — local evidence")
struct YearLocalEvidenceTests {
    private let determinator = YearDeterminator()

    @Test("Consensus release year used when all tracks agree")
    func consensusYear() {
        let track = makeTrack(year: 2000)
        let albumTracks = [
            Track(id: "1", name: "A", artist: "X", album: "Y", releaseYear: 2005),
            Track(id: "2", name: "B", artist: "X", album: "Y", releaseYear: 2005),
            Track(id: "3", name: "C", artist: "X", album: "Y", releaseYear: 2005),
        ]

        let result = determinator.determineYear(
            candidates: [makeCandidate(year: 2003)],
            track: track,
            albumTracks: albumTracks,
            currentYear: 2000
        )

        #expect(result.yearResult.year == 2005)
        #expect(result.source == .consensus)
        #expect(result.yearResult.confidence == 80)
        #expect(result.yearResult.isDefinitive == true)
    }

    @Test("Consensus uses the one release year present across partial metadata")
    func consensusUsesPresentReleaseYear() {
        let track = makeTrack(year: 2000)
        let albumTracks = [
            Track(id: "1", name: "A", artist: "X", album: "Y", releaseYear: 2010),
            Track(id: "2", name: "B", artist: "X", album: "Y", releaseYear: nil),
        ]

        let result = determinator.determineYear(
            candidates: [],
            track: track,
            albumTracks: albumTracks,
            currentYear: 2000
        )

        #expect(result.yearResult.year == 2010)
        #expect(result.source == .consensus)
        #expect(result.yearResult.confidence == 80)
        #expect(result.yearResult.isDefinitive == true)
    }

    @Test("Consensus release year overrides invalid dominant track year")
    func consensusOverridesInvalidDominantYear() {
        let track = makeTrack(year: 2211)
        let albumTracks = [
            Track(
                id: "1",
                name: "The Elephant Riders",
                artist: "Clutch",
                album: "The Elephant Riders",
                year: 2211,
                releaseYear: 1998
            ),
            Track(
                id: "2",
                name: "Ship of Gold",
                artist: "Clutch",
                album: "The Elephant Riders",
                year: 2211,
                releaseYear: 1998
            ),
            Track(
                id: "3",
                name: "Eight Times Over Miss October",
                artist: "Clutch",
                album: "The Elephant Riders",
                year: 2211,
                releaseYear: 1998
            ),
        ]

        let result = determinator.determineYear(
            candidates: [],
            track: track,
            albumTracks: albumTracks,
            currentYear: 2211
        )

        #expect(result.yearResult.year == 1998)
        #expect(result.source == .consensus)
        #expect(result.yearResult.isDefinitive == true)
    }

    @Test("Consensus skipped when tracks disagree")
    func noConsensus() {
        let track = makeTrack(year: 2000)
        let albumTracks = [
            Track(id: "1", name: "A", artist: "X", album: "Y", releaseYear: 2005),
            Track(id: "2", name: "B", artist: "X", album: "Y", releaseYear: 2006),
        ]

        let result = determinator.determineYear(
            candidates: [makeCandidate(artist: "X", album: "Y", year: 2005)],
            track: track,
            albumTracks: albumTracks,
            currentYear: 2000
        )

        #expect(result.source != .consensus)
    }

    @Test("Dominant year used with high confidence")
    func dominantYear() {
        let albumTracks = [
            Track(id: "1", name: "A", artist: "X", album: "Y", year: 2005),
            Track(id: "2", name: "B", artist: "X", album: "Y", year: 2005),
            Track(id: "3", name: "C", artist: "X", album: "Y", year: 2005),
            Track(id: "4", name: "D", artist: "X", album: "Y", year: 2005),
            Track(id: "5", name: "E", artist: "X", album: "Y", year: 2006),
        ]

        let result = determinator.determineYear(
            candidates: [makeCandidate(year: 2003)],
            track: makeTrack(),
            albumTracks: albumTracks
        )

        #expect(result.yearResult.year == 2005)
        #expect(result.source == .dominant)
    }

    @Test("Year below the dominance threshold falls through to scoring")
    func belowThresholdYearFallsThrough() {
        let albumTracks = [
            Track(id: "1", name: "A", artist: "X", album: "Y", year: 2005),
            Track(id: "2", name: "B", artist: "X", album: "Y", year: 2005),
            Track(id: "3", name: "C", artist: "X", album: "Y", year: 2006),
            Track(id: "4", name: "D", artist: "X", album: "Y", year: 2007),
            Track(id: "5", name: "E", artist: "X", album: "Y", year: 2008),
        ]

        let result = determinator.determineYear(
            candidates: [makeCandidate(artist: "X", album: "Y", year: 2005)],
            track: makeTrack(),
            albumTracks: albumTracks
        )

        #expect(result.source != .dominant)
    }

    private func makeTrack(year: Int? = nil) -> Track {
        Track(
            id: "test-1",
            name: "Test Song",
            artist: "Test Artist",
            album: "Test Album",
            year: year
        )
    }

    private func makeCandidate(
        artist: String = "Test Artist",
        album: String = "Test Album",
        year: Int
    ) -> ReleaseCandidate {
        ReleaseCandidate(
            artist: artist,
            album: album,
            year: year,
            source: .musicBrainz,
            releaseType: .album,
            status: .official,
            country: "US",
            isReissue: false,
            mbReleaseGroupID: "rg-1"
        )
    }
}
