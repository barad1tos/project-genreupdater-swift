import Foundation
import Testing
@testable import Core

@Suite("YearDeterminator — Release Year Verification")
struct ReleaseYearTests {
    private let determinator = YearDeterminator()

    @Test("Consensus release year requires complete album coverage")
    func consensusReleaseYearRequiresCompleteAlbumCoverage() {
        let track = makeTrack()
        let albumTracks = [
            Track(
                id: "1",
                name: "A",
                artist: "X",
                album: "Y",
                releaseYear: 2005
            ),
            Track(
                id: "2",
                name: "B",
                artist: "X",
                album: "Y"
            ),
        ]

        let result = determinator.determineYear(
            candidates: [],
            track: track,
            albumTracks: albumTracks
        )

        #expect(result.yearResult.year == nil)
        #expect(result.source == .fallback)
    }

    @Test("Valid dominant editable year wins over conflicting release year locally")
    func validDominantEditableYearWinsOverConflictingReleaseYearLocally() {
        let track = makeTrack(year: 2023)
        let albumTracks = [
            Track(
                id: "1",
                name: "Sugar Creek",
                artist: "SubRosa",
                album: "Strega",
                year: 2023,
                releaseYear: 2008
            ),
            Track(
                id: "2",
                name: "Crucible",
                artist: "SubRosa",
                album: "Strega",
                year: 2023,
                releaseYear: 2008
            ),
            Track(
                id: "3",
                name: "Christine",
                artist: "SubRosa",
                album: "Strega",
                year: 2023,
                releaseYear: 2008
            ),
        ]

        let result = determinator.determineYear(
            candidates: [],
            track: track,
            albumTracks: albumTracks,
            currentYear: 2023
        )

        #expect(result.yearResult.year == 2023)
        #expect(result.source == .dominant)
        #expect(result.yearResult.isDefinitive == true)
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
}
