import Foundation
import Testing
@testable import Services

@Suite("MusicLibraryReader — MusicKit conversion")
struct MusicLibraryReaderTests {
    @Test("MusicKit release date maps to releaseYear, not editable year")
    func musicKitReleaseDateDoesNotPopulateEditableYear() throws {
        let releaseDate = try #require(DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2023,
            month: 2,
            day: 10
        ).date)

        let track = MusicLibraryReader.makeTrackFromMusicKitMetadata(MusicLibraryReader.MusicKitTrackMetadata(
            id: "music-kit-id",
            name: "Foregone Pt. 1",
            artist: "In Flames",
            album: "Foregone",
            genres: ["Melodic Death Metal"],
            releaseDate: releaseDate,
            libraryAddedDate: nil
        ))

        #expect(track.year == nil)
        #expect(track.releaseYear == 2023)
        #expect(track.genre == "Melodic Death Metal")
    }

    @Test("Requested artist resolves to a single scoped fetch target")
    func requestedArtistResolvesToScopedFetchTarget() {
        let targets = MusicLibraryReader.fetchTargets(
            requestedArtist: "  In Flames  ",
            testArtists: ["Beatles"],
            ignoreTestFilter: false
        )

        #expect(targets == ["In Flames"])
    }

    @Test("Test artists resolve to scoped fetch targets")
    func artistsResolveToScopedFetchTargets() {
        let targets = MusicLibraryReader.fetchTargets(
            requestedArtist: nil,
            testArtists: ["In Flames", "  ", "in flames", "Beatles"],
            ignoreTestFilter: false
        )

        #expect(targets == ["In Flames", "Beatles"])
    }

    @Test("Ignoring test filter resolves to full-library fetch target")
    func ignoreTestFilterResolvesToFullLibraryFetchTarget() {
        let targets = MusicLibraryReader.fetchTargets(
            requestedArtist: nil,
            testArtists: ["In Flames"],
            ignoreTestFilter: true
        )

        #expect(targets == [nil])
    }

    @Test("Empty artist scope resolves to full-library fetch target")
    func emptyArtistScopeResolvesToFullLibraryFetchTarget() {
        let targets = MusicLibraryReader.fetchTargets(
            requestedArtist: nil,
            testArtists: [],
            ignoreTestFilter: false
        )

        #expect(targets == [nil])
    }
}
