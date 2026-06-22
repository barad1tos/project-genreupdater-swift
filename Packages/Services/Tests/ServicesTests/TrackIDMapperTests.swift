import Foundation
import Testing
@testable import Core
@testable import Services

// MARK: - Helpers

private func makeTrack(
    id: String,
    name: String = "Song",
    artist: String = "Artist",
    album: String = "Album",
    genre: String? = nil,
    year: Int? = nil,
    trackStatus: String? = nil,
    releaseYear: Int? = nil,
    albumArtist: String? = nil
) -> Track {
    Track(
        id: id,
        name: name,
        artist: artist,
        album: album,
        genre: genre,
        year: year,
        trackStatus: trackStatus,
        releaseYear: releaseYear,
        albumArtist: albumArtist
    )
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

    @Test("Duplicate AppleScript keys are treated as ambiguous")
    func duplicateAppleScriptKeysAreAmbiguous() async {
        let mapper = TrackIDMapper()

        let musicKitTrack = makeTrack(id: "MK1", name: "Song", artist: "Artist", album: "Album")
        let appleScriptTracks = [
            makeTrack(id: "AS-FIRST", name: "Song", artist: "Artist", album: "Album"),
            makeTrack(id: "AS-SECOND", name: "Song", artist: "Artist", album: "Album"),
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
            makeTrack(id: "MK2", name: "Song", artist: "Artist", album: "Album"),
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

    @Test("Album artist fallback maps variant track artists")
    func albumArtistFallbackMapsVariantTrackArtists() async throws {
        let mapper = TrackIDMapper()
        let musicKitTrack = makeTrack(
            id: "MK1",
            name: "Immortal",
            artist: "Clutch feat. Leslie West",
            album: "Pure Rock Fury",
            albumArtist: "Clutch"
        )
        let appleScriptTrack = makeTrack(
            id: "AS-HEX-1",
            name: "Immortal",
            artist: "Clutch",
            album: "Pure Rock Fury",
            year: 2001,
            albumArtist: "Clutch"
        )

        await mapper.refreshMapping(
            musicKitTracks: [musicKitTrack],
            appleScriptTracks: [appleScriptTrack]
        )

        let writeID = await mapper.appleScriptID(forMusicKitID: "MK1")
        let enrichedTrack = try #require(await mapper.trackWithAppleScriptMetadata(for: musicKitTrack))

        #expect(writeID == "AS-HEX-1")
        #expect(enrichedTrack.id == "MK1")
        #expect(enrichedTrack.year == 2001)
        #expect(enrichedTrack.artist == "Clutch")
        #expect(enrichedTrack.albumArtist == "Clutch")
    }

    @Test("Ambiguous album artist fallback is not mapped")
    func ambiguousAlbumArtistFallbackIsNotMapped() async {
        let mapper = TrackIDMapper()
        let musicKitTrack = makeTrack(
            id: "MK1",
            name: "Intro",
            artist: "Unknown Performer",
            album: "Compilation",
            albumArtist: "Various Artists"
        )
        let appleScriptTracks = [
            makeTrack(
                id: "AS-FIRST",
                name: "Intro",
                artist: "Performer One",
                album: "Compilation",
                albumArtist: "Various Artists"
            ),
            makeTrack(
                id: "AS-SECOND",
                name: "Intro",
                artist: "Performer Two",
                album: "Compilation",
                albumArtist: "Various Artists"
            ),
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

    @Test("Unscoped refresh fetches AppleScript IDs before metadata details")
    func unscopedRefreshFetchesAppleScriptIDsBeforeMetadataDetails() async throws {
        let mapper = TrackIDMapper()
        let bridge = MockAppleScriptClient()
        let musicKitTracks = [
            makeTrack(id: "MK-CLUTCH", name: "Immortal", artist: "Clutch", album: "Pure Rock Fury"),
        ]
        let appleScriptTracks = [
            makeTrack(id: "AS-CLUTCH", name: "Immortal", artist: "Clutch", album: "Pure Rock Fury"),
        ]
        await bridge.setFetchedTracks(appleScriptTracks)

        let mappedCount = try await mapper.refreshMapping(
            musicKitTracks: musicKitTracks,
            appleScriptClient: bridge,
            batchSize: 37,
            allTrackIDsTimeout: .seconds(4),
            tracksByIDsTimeout: .seconds(9)
        )

        let detailsFetch = try #require(await bridge.fetchTracksByIDsCalls().first)
        #expect(mappedCount == 1)
        #expect(await bridge.fetchAllTrackIDsTimeouts() == [.seconds(4)])
        #expect(detailsFetch.trackIDs == ["AS-CLUTCH"])
        #expect(detailsFetch.batchSize == 37)
        #expect(detailsFetch.timeout == .seconds(9))
        #expect(await mapper.appleScriptID(forMusicKitID: "MK-CLUTCH") == "AS-CLUTCH")
    }

    @Test("Refresh with test artists fetches scoped AppleScript tracks")
    func refreshWithTestArtistsFetchesScopedAppleScriptTracks() async throws {
        let mapper = TrackIDMapper()
        let bridge = ScopedTrackMappingScriptClient(scopedTracks: [
            "In Flames": [
                makeTrack(id: "AS-IN", name: "Only for the Weak", artist: "In Flames", album: "Clayman"),
            ],
        ])
        let musicKitTracks = [
            makeTrack(id: "MK-IN", name: "Only for the Weak", artist: "In Flames", album: "Clayman"),
            makeTrack(id: "MK-OUT", name: "Come Together", artist: "Beatles", album: "Abbey Road"),
        ]

        let mappedCount = try await mapper.refreshMapping(
            musicKitTracks: musicKitTracks,
            appleScriptClient: bridge,
            batchSize: 50,
            allTrackIDsTimeout: .seconds(5),
            tracksByIDsTimeout: .seconds(10),
            testArtists: ["In Flames"]
        )

        #expect(mappedCount == 1)
        #expect(await bridge.didFetchAllTrackIDs() == false)
        #expect(await bridge.requestedArtists() == ["In Flames"])
        #expect(await mapper.appleScriptID(forMusicKitID: "MK-IN") == "AS-IN")
        #expect(await mapper.appleScriptID(forMusicKitID: "MK-OUT") == nil)
    }

    @Test("Enrichment keeps MusicKit ID and uses AppleScript writable metadata")
    func enrichmentKeepsMusicKitIDAndUsesAppleScriptMetadata() async throws {
        let mapper = TrackIDMapper()
        let musicKitTrack = makeTrack(
            id: "MK1",
            name: "Foregone Pt. 1",
            artist: "In Flames",
            album: "Foregone",
            year: nil,
            releaseYear: 2023
        )
        let appleScriptTrack = makeTrack(
            id: "AS-HEX-1",
            name: "Foregone Pt. 1",
            artist: "In Flames",
            album: "Foregone",
            genre: "Melodic Death Metal",
            year: 2021,
            trackStatus: "subscription",
            releaseYear: 2023,
            albumArtist: "In Flames"
        )

        await mapper.refreshMapping(
            musicKitTracks: [musicKitTrack],
            appleScriptTracks: [appleScriptTrack]
        )

        let enriched = try #require(await mapper.trackWithAppleScriptMetadata(for: musicKitTrack))
        #expect(enriched.id == "MK1")
        #expect(enriched.year == 2021)
        #expect(enriched.releaseYear == 2023)
        #expect(enriched.genre == "Melodic Death Metal")
        #expect(enriched.trackStatus == "subscription")
        #expect(enriched.albumArtist == "In Flames")
    }
}

private actor ScopedTrackMappingScriptClient: AppleScriptClient {
    private let scopedTracks: [String: [Track]]
    private var fetchedAllTrackIDs = false
    private var artistRequests: [String] = []

    init(scopedTracks: [String: [Track]]) {
        self.scopedTracks = scopedTracks
    }

    func initialize() async throws {
        try Task.checkCancellation()
    }

    func runScript(
        name _: String,
        arguments _: [String],
        timeout _: Duration?
    ) async throws -> String? {
        nil
    }

    func fetchTracks(
        artist: String?,
        timeout _: Duration?
    ) async throws -> [Track] {
        guard let artist else { return [] }
        artistRequests.append(artist)
        return scopedTracks[artist] ?? []
    }

    func fetchTracksByIDs(
        _: [String],
        batchSize _: Int,
        timeout _: Duration?
    ) async throws -> [Track] {
        []
    }

    func fetchAllTrackIDs(timeout _: Duration?) async throws -> [String] {
        fetchedAllTrackIDs = true
        return []
    }

    func updateTrackProperty(
        trackID _: String,
        property _: String,
        value _: String
    ) async throws -> AppleScriptWriteResult {
        try Task.checkCancellation()
        return .changed
    }

    func batchUpdateTracks(
        _: [(trackID: String, property: String, value: String)]
    ) async throws {
        try Task.checkCancellation()
    }

    func didFetchAllTrackIDs() -> Bool {
        fetchedAllTrackIDs
    }

    func requestedArtists() -> [String] {
        artistRequests
    }
}
