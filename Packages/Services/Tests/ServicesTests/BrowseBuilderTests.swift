import Core
import Foundation
import Testing
@testable import Services

// MARK: - Fixtures

private func makeTrack(
    id: String = UUID().uuidString,
    name: String = "Song",
    artist: String,
    album: String,
    albumArtist: String? = nil,
    genre: String? = nil,
    year: Int? = nil,
    originalPosition: Int? = nil,
    appleScriptID: String? = "as-id"
) -> Track {
    Track(
        id: id,
        name: name,
        artist: artist,
        album: album,
        genre: genre,
        year: year,
        originalPosition: originalPosition,
        albumArtist: albumArtist,
        appleScriptID: appleScriptID
    )
}

private func makeInput(
    tracks: [Track],
    testArtists: [String] = [],
    physicalTrackCount: Int? = nil,
    previewUnavailableReason: String? = nil
) -> BrowseInput {
    BrowseInput(
        tracks: tracks,
        scope: ProcessingScopeSnapshot.capture(
            requestedTestArtists: testArtists,
            knownTrackCount: tracks.count,
            createdAt: Date(timeIntervalSince1970: 100),
            reason: "browse-test"
        ),
        physicalTrackCount: physicalTrackCount,
        readSource: .liveLibrary(scannedAt: Date(timeIntervalSince1970: 100)),
        previewUnavailableReason: previewUnavailableReason
    )
}

// MARK: - Grouping

@Suite("Browse builder grouping")
struct BrowseBuilderGroupingTests {
    @Test("albumArtist groups a split-artist album into one node")
    func albumArtistWinsGrouping() {
        let projection = BrowseBuilder.makeProjection(input: makeInput(tracks: [
            makeTrack(artist: "Artist feat. Guest", album: "One", albumArtist: "Artist"),
            makeTrack(artist: "Artist", album: "One", albumArtist: "Artist"),
        ]))

        #expect(projection.artists.count == 1)
        #expect(projection.artists[0].albums.count == 1)
        #expect(projection.artists[0].albums[0].counts.total == 2)
    }

    @Test("case variants merge into one artist node with a stable id")
    func caseVariantsMerge() {
        let projection = BrowseBuilder.makeProjection(input: makeInput(tracks: [
            makeTrack(artist: "Metallica", album: "Ride the Lightning"),
            makeTrack(artist: "metallica", album: "Kill 'Em All"),
        ]))

        #expect(projection.artists.count == 1)
        let artist = projection.artists[0]
        #expect(artist.id == normalizeForMatching("Metallica"))
        #expect(artist.name == "Metallica")
        #expect(artist.albums.count == 2)
    }

    @Test("the album id is the normalized AlbumIdentity key")
    func albumIDIsIdentityKey() {
        let projection = BrowseBuilder.makeProjection(input: makeInput(tracks: [
            makeTrack(artist: "Clutch", album: "Blast Tyrant"),
        ]))

        let expectedKey = AlbumIdentity(artist: "Clutch", album: "Blast Tyrant").key
        #expect(projection.artists[0].albums[0].id == expectedKey)
    }

    @Test("display genre and year are the most frequent values, ties smallest")
    func dominantDisplayValues() {
        let projection = BrowseBuilder.makeProjection(input: makeInput(tracks: [
            makeTrack(artist: "Artist", album: "One", genre: "Rock", year: 2004),
            makeTrack(artist: "Artist", album: "One", genre: "Rock", year: 2004),
            makeTrack(artist: "Artist", album: "One", genre: "Jazz", year: nil),
            makeTrack(artist: "Artist", album: "Two", genre: "Rock", year: 2001),
            makeTrack(artist: "Artist", album: "Two", genre: "Jazz", year: 1999),
        ]))

        let albums = projection.artists[0].albums
        let one = albums.first { $0.title == "One" }
        let two = albums.first { $0.title == "Two" }

        #expect(one?.genre == "Rock")
        #expect(one?.year == 2004)
        // A 1-1 tie resolves to the smallest value.
        #expect(two?.genre == "Jazz")
        #expect(two?.year == 1999)
    }

    @Test("artists sort by name, albums by year then title, unknown year last")
    func sortOrder() {
        let projection = BrowseBuilder.makeProjection(input: makeInput(tracks: [
            makeTrack(artist: "Beatles", album: "Revolver", year: 1966),
            makeTrack(artist: "Anthrax", album: "Zeta", year: 2001),
            makeTrack(artist: "Anthrax", album: "Beta", year: 1999),
            makeTrack(artist: "Anthrax", album: "Alpha", year: nil),
        ]))

        #expect(projection.artists.map(\.name) == ["Anthrax", "Beatles"])
        #expect(projection.artists[0].albums.map(\.title) == ["Beta", "Zeta", "Alpha"])
    }
}
