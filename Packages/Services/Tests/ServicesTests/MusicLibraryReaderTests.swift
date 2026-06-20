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
}
