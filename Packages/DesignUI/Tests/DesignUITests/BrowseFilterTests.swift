import Foundation
import Testing
@testable import DesignUI

@Suite("Browse triage filter")
struct BrowseFilterTests {
    private func album(id: String, genre: String?, year: Int?) -> Album {
        Album(
            id: id,
            name: id,
            artistName: "Artist",
            genre: genre,
            year: year,
            counts: DesignBrowseCounts(tracks: 1, inScope: 1, writable: 1),
            action: DesignBrowseAction(title: "Preview changes", isEnabled: true, disabledReason: nil)
        )
    }

    @Test("fact filters keep only albums missing that fact")
    func factFilters() {
        let artists = [Artist(id: "a", name: "Artist", albums: [
            album(id: "complete", genre: "Rock", year: 2000),
            album(id: "no-genre", genre: nil, year: 2000),
            album(id: "no-year", genre: "Rock", year: nil),
        ])]

        let missingGenre = BrowseView.filterArtists(artists, filter: .missingGenre, query: "")
        let missingYear = BrowseView.filterArtists(artists, filter: .missingYear, query: "")

        #expect(missingGenre.flatMap(\.albums).map(\.id) == ["no-genre"])
        #expect(missingYear.flatMap(\.albums).map(\.id) == ["no-year"])
    }

    @Test("search matches artist names and drops emptied artists")
    func searchByArtistName() {
        let artists = [
            Artist(id: "a", name: "Clutch", albums: [album(id: "one", genre: nil, year: nil)]),
            Artist(id: "b", name: "Anthrax", albums: [album(id: "two", genre: nil, year: nil)]),
        ]

        let filtered = BrowseView.filterArtists(artists, filter: .all, query: "clu")

        #expect(filtered.map(\.name) == ["Clutch"])
    }
}
