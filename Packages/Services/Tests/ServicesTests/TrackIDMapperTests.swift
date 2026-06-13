import Foundation
import Testing
@testable import Core
@testable import Services

// MARK: - Helpers

private func makeTrack(
    id: String,
    name: String = "Song",
    artist: String = "Artist",
    album: String = "Album"
) -> Track {
    Track(id: id, name: name, artist: artist, album: album)
}

// MARK: - Tests

@Suite("TrackIDMapper — MusicKit ↔ AppleScript ID mapping")
struct TrackIDMapperTests {
    @Test("Matches tracks by name, artist, album")
    func refreshMappingMatchesByNameArtistAlbum() async {
        let mapper = TrackIDMapper()

        let musicKitTracks = [
            makeTrack(id: "MK1", name: "Come Together", artist: "Beatles", album: "Abbey Road"),
            makeTrack(id: "MK2", name: "Something", artist: "Beatles", album: "Abbey Road"),
        ]
        let appleScriptTracks = [
            makeTrack(id: "AS-HEX-1", name: "Come Together", artist: "Beatles", album: "Abbey Road"),
            makeTrack(id: "AS-HEX-2", name: "Something", artist: "Beatles", album: "Abbey Road"),
        ]

        await mapper.refreshMapping(
            musicKitTracks: musicKitTracks,
            appleScriptTracks: appleScriptTracks
        )

        let result1 = await mapper.appleScriptID(forMusicKitID: "MK1")
        #expect(result1 == "AS-HEX-1")

        let result2 = await mapper.appleScriptID(forMusicKitID: "MK2")
        #expect(result2 == "AS-HEX-2")
    }

    @Test("Unmatched track returns nil")
    func unmatchedTrackReturnsNil() async {
        let mapper = TrackIDMapper()

        let musicKitTracks = [
            makeTrack(id: "MK1", name: "Unique Song", artist: "Unknown", album: "NoMatch"),
        ]
        let appleScriptTracks = [
            makeTrack(id: "AS1", name: "Different Song", artist: "Other", album: "Other Album"),
        ]

        await mapper.refreshMapping(
            musicKitTracks: musicKitTracks,
            appleScriptTracks: appleScriptTracks
        )

        let result = await mapper.appleScriptID(forMusicKitID: "MK1")
        #expect(result == nil)

        let hasMapping = await mapper.hasMappingFor(musicKitID: "MK1")
        #expect(!hasMapping)
    }

    @Test("Matching is case-insensitive")
    func caseInsensitiveMatching() async {
        let mapper = TrackIDMapper()

        let musicKitTracks = [
            makeTrack(id: "MK1", name: "Come Together", artist: "THE BEATLES", album: "ABBEY ROAD"),
        ]
        let appleScriptTracks = [
            makeTrack(id: "AS1", name: "come together", artist: "the beatles", album: "abbey road"),
        ]

        await mapper.refreshMapping(
            musicKitTracks: musicKitTracks,
            appleScriptTracks: appleScriptTracks
        )

        let result = await mapper.appleScriptID(forMusicKitID: "MK1")
        #expect(result == "AS1")
    }

    @Test("Duplicate keys: last AppleScript track wins")
    func duplicateKeysLastWins() async {
        let mapper = TrackIDMapper()

        let musicKitTracks = [
            makeTrack(id: "MK1", name: "Song", artist: "Artist", album: "Album"),
        ]
        let appleScriptTracks = [
            makeTrack(id: "AS-FIRST", name: "Song", artist: "Artist", album: "Album"),
            makeTrack(id: "AS-SECOND", name: "Song", artist: "Artist", album: "Album"),
        ]

        await mapper.refreshMapping(
            musicKitTracks: musicKitTracks,
            appleScriptTracks: appleScriptTracks
        )

        let result = await mapper.appleScriptID(forMusicKitID: "MK1")
        #expect(result == "AS-SECOND")
    }

    @Test("Empty input produces empty mapping")
    func emptyInputProducesEmptyMapping() async {
        let mapper = TrackIDMapper()

        await mapper.refreshMapping(musicKitTracks: [], appleScriptTracks: [])

        let result = await mapper.appleScriptID(forMusicKitID: "any")
        #expect(result == nil)

        let hasMapping = await mapper.hasMappingFor(musicKitID: "any")
        #expect(!hasMapping)
    }

    @Test("Refresh from AppleScript client maps MusicKit tracks to fetched AppleScript IDs")
    func refreshFromAppleScriptClientMapsFetchedTracks() async throws {
        let mapper = TrackIDMapper()
        let bridge = MockAppleScriptClient()
        let musicKitTracks = [
            makeTrack(id: "MK1", name: "Come Together", artist: "Beatles", album: "Abbey Road"),
            makeTrack(id: "MK2", name: "Something", artist: "Beatles", album: "Abbey Road"),
        ]
        let appleScriptTracks = [
            makeTrack(id: "AS-HEX-1", name: "Come Together", artist: "Beatles", album: "Abbey Road"),
            makeTrack(id: "AS-HEX-2", name: "Something", artist: "Beatles", album: "Abbey Road"),
        ]
        await bridge.setFetchedTracks(appleScriptTracks)

        let mappedCount = try await mapper.refreshMapping(
            musicKitTracks: musicKitTracks,
            appleScriptClient: bridge,
            batchSize: 50,
            allTrackIDsTimeout: .seconds(5),
            tracksByIDsTimeout: .seconds(10)
        )

        #expect(mappedCount == 2)
        #expect(await mapper.appleScriptID(forMusicKitID: "MK1") == "AS-HEX-1")
        #expect(await mapper.appleScriptID(forMusicKitID: "MK2") == "AS-HEX-2")
    }
}
