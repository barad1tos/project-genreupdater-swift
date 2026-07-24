import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("TrackIDMapper client refresh")
struct TrackIDRefreshTests {
    @Test("Refresh from AppleScript client maps MusicKit tracks to fetched AppleScript IDs")
    func refreshFromAppleScriptClientMapsFetchedTracks() async throws {
        let mapper = TrackIDMapper()
        let bridge = MockAppleScriptClient()
        let musicKitTracks = [
            makeTrack(id: "MK1", name: "Come Together", artist: "Beatles", album: "Abbey Road"),
            makeTrack(id: "MK2", name: "Something", artist: "Beatles", album: "Abbey Road")
        ]
        let appleScriptTracks = [
            makeTrack(id: "AS-HEX-1", name: "Come Together", artist: "Beatles", album: "Abbey Road"),
            makeTrack(id: "AS-HEX-2", name: "Something", artist: "Beatles", album: "Abbey Road")
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
            makeTrack(id: "MK-CLUTCH", name: "Immortal", artist: "Clutch", album: "Pure Rock Fury")
        ]
        let appleScriptTracks = [
            makeTrack(id: "AS-CLUTCH", name: "Immortal", artist: "Clutch", album: "Pure Rock Fury")
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
                makeTrack(id: "AS-IN", name: "Only for the Weak", artist: "In Flames", album: "Clayman")
            ]
        ])
        let musicKitTracks = [
            makeTrack(id: "MK-IN", name: "Only for the Weak", artist: "In Flames", album: "Clayman"),
            makeTrack(id: "MK-OUT", name: "Come Together", artist: "Beatles", album: "Abbey Road")
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

    @Test("Merge refresh preserves existing mappings while adding scoped tracks")
    func mergeRefreshPreservesExistingMappings() async {
        let mapper = TrackIDMapper()
        let clutchTrack = makeTrack(id: "MK-CLUTCH", name: "Immortal", artist: "Clutch", album: "Pure Rock Fury")
        let massiveAttackTrack = makeTrack(id: "MK-MA", name: "Angel", artist: "Massive Attack", album: "Mezzanine")

        await mapper.refreshMapping(
            musicKitTracks: [clutchTrack],
            appleScriptTracks: [
                makeTrack(id: "AS-CLUTCH", name: "Immortal", artist: "Clutch", album: "Pure Rock Fury")
            ]
        )
        await mapper.refreshMapping(
            musicKitTracks: [massiveAttackTrack],
            appleScriptTracks: [
                makeTrack(id: "AS-MA", name: "Angel", artist: "Massive Attack", album: "Mezzanine")
            ],
            mergeExisting: true
        )

        #expect(await mapper.appleScriptID(forMusicKitID: "MK-CLUTCH") == "AS-CLUTCH")
        #expect(await mapper.appleScriptID(forMusicKitID: "MK-MA") == "AS-MA")
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
        _: [TrackPropertyUpdate]
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
