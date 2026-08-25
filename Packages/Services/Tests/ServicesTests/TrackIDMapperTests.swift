import Foundation
import Testing
@testable import Core
@testable import Services

// MARK: - Helpers

struct TrackMetadataFixture {
    var genre: String?
    var year: Int?
    var trackStatus: String?
    var releaseYear: Int?
    var albumArtist: String?
}

func makeTrack(
    id: String,
    name: String = "Song",
    artist: String = "Artist",
    album: String = "Album",
    metadata: TrackMetadataFixture = .init()
) -> Track {
    Track(
        id: id,
        name: name,
        artist: artist,
        album: album,
        genre: metadata.genre,
        year: metadata.year,
        trackStatus: metadata.trackStatus,
        releaseYear: metadata.releaseYear,
        albumArtist: metadata.albumArtist
    )
}

// MARK: - Tests

@Suite("TrackIDMapper — MusicKit ↔ AppleScript ID mapping")
struct TrackIDMapperTests {
    @Test("Pure resolution does not mutate mapper state")
    func pureResolutionDoesNotMutateState() async {
        let mapper = TrackIDMapper()
        let source = makeTrack(id: "MK1", name: "Song", artist: "Artist", album: "Album")
        let target = makeTrack(id: "AS1", name: "Song", artist: "Artist", album: "Album")

        let resolution = TrackIDMapper.resolve(
            sourceTracks: [source],
            targetTracks: [target]
        )

        #expect(resolution.matches["MK1"]?.id == "AS1")
        #expect(resolution.ambiguous.isEmpty)
        #expect(resolution.unresolved.isEmpty)
        #expect(await mapper.appleScriptID(forMusicKitID: "MK1") == nil)
    }

    @Test("Pure resolution reports deterministic ambiguity and unresolved sources")
    func pureResolutionReportsFailures() {
        let ambiguous = makeTrack(id: "MK1", name: "Song", artist: "Artist", album: "Album")
        let unresolved = makeTrack(id: "MK2", name: "Missing", artist: "Artist", album: "Album")
        let targets = [
            makeTrack(id: "AS2", name: "Song", artist: "Artist", album: "Album"),
            makeTrack(id: "AS1", name: "Song", artist: "Artist", album: "Album")
        ]

        let resolution = TrackIDMapper.resolve(
            sourceTracks: [unresolved, ambiguous],
            targetTracks: targets
        )

        #expect(resolution.matches.isEmpty)
        #expect(resolution.ambiguous == ["MK1": ["AS1", "AS2"]])
        #expect(resolution.unresolved == ["MK2"])
    }

    @Test("Matches tracks by name, artist, album")
    func refreshMappingMatchesByNameArtistAlbum() async {
        let mapper = TrackIDMapper()

        let musicKitTracks = [
            makeTrack(id: "MK1", name: "Come Together", artist: "Beatles", album: "Abbey Road"),
            makeTrack(id: "MK2", name: "Something", artist: "Beatles", album: "Abbey Road")
        ]
        let appleScriptTracks = [
            makeTrack(id: "AS-HEX-1", name: "Come Together", artist: "Beatles", album: "Abbey Road"),
            makeTrack(id: "AS-HEX-2", name: "Something", artist: "Beatles", album: "Abbey Road")
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
            makeTrack(id: "MK1", name: "Unique Song", artist: "Unknown", album: "NoMatch")
        ]
        let appleScriptTracks = [
            makeTrack(id: "AS1", name: "Different Song", artist: "Other", album: "Other Album")
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
            makeTrack(id: "MK1", name: "Come Together", artist: "THE BEATLES", album: "ABBEY ROAD")
        ]
        let appleScriptTracks = [
            makeTrack(id: "AS1", name: "come together", artist: "the beatles", album: "abbey road")
        ]

        await mapper.refreshMapping(
            musicKitTracks: musicKitTracks,
            appleScriptTracks: appleScriptTracks
        )

        let result = await mapper.appleScriptID(forMusicKitID: "MK1")
        #expect(result == "AS1")
    }

    @Test("Duplicate AppleScript keys are treated as ambiguous")
    func duplicateAppleScriptKeysAreAmbiguous() async {
        let mapper = TrackIDMapper()

        let musicKitTrack = makeTrack(id: "MK1", name: "Song", artist: "Artist", album: "Album")
        let appleScriptTracks = [
            makeTrack(id: "AS-FIRST", name: "Song", artist: "Artist", album: "Album"),
            makeTrack(id: "AS-SECOND", name: "Song", artist: "Artist", album: "Album")
        ]

        await mapper.refreshMapping(
            musicKitTracks: [musicKitTrack],
            appleScriptTracks: appleScriptTracks
        )

        let writeID = await mapper.appleScriptID(forMusicKitID: "MK1")
        let enrichedTrack = await mapper.trackWithAppleScriptMetadata(for: musicKitTrack)

        #expect(writeID == nil)
        #expect(enrichedTrack == nil)
    }

    @Test("Duplicate MusicKit keys are treated as ambiguous")
    func duplicateMusicKitKeysAreAmbiguous() async {
        let mapper = TrackIDMapper()

        let musicKitTracks = [
            makeTrack(id: "MK1", name: "Song", artist: "Artist", album: "Album"),
            makeTrack(id: "MK2", name: "Song", artist: "Artist", album: "Album")
        ]
        let appleScriptTrack = makeTrack(id: "AS1", name: "Song", artist: "Artist", album: "Album")

        await mapper.refreshMapping(
            musicKitTracks: musicKitTracks,
            appleScriptTracks: [appleScriptTrack]
        )

        let firstWriteID = await mapper.appleScriptID(forMusicKitID: "MK1")
        let secondWriteID = await mapper.appleScriptID(forMusicKitID: "MK2")
        let firstEnrichedTrack = await mapper.trackWithAppleScriptMetadata(for: musicKitTracks[0])
        let secondEnrichedTrack = await mapper.trackWithAppleScriptMetadata(for: musicKitTracks[1])

        #expect(firstWriteID == nil)
        #expect(secondWriteID == nil)
        #expect(firstEnrichedTrack == nil)
        #expect(secondEnrichedTrack == nil)
    }

    @Test("Empty input produces empty mapping")
    func emptyInputProducesEmptyMapping() async {
        let mapper = TrackIDMapper()

        await mapper.refreshMapping(musicKitTracks: [], appleScriptTracks: [], mergeExisting: false)

        let result = await mapper.appleScriptID(forMusicKitID: "any")
        #expect(result == nil)

        let hasMapping = await mapper.hasMappingFor(musicKitID: "any")
        #expect(!hasMapping)
    }
}
