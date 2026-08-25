import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("TrackIDMapper client refresh")
struct TrackIDRefreshTests {
    @Test("Refresh from identity source maps MusicKit tracks to fetched AppleScript IDs")
    func refreshFromIdentitySourceMapsFetchedTracks() async throws {
        let mapper = TrackIDMapper()
        let bridge = MusicAppTestAccess()
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
            identitySource: bridge
        )

        #expect(mappedCount == 2)
        #expect(await mapper.appleScriptID(forMusicKitID: "MK1") == "AS-HEX-1")
        #expect(await mapper.appleScriptID(forMusicKitID: "MK2") == "AS-HEX-2")
    }

    @Test("Unscoped refresh requests the full canonical identity surface")
    func unscopedRefreshRequestsFullIdentitySurface() async throws {
        let mapper = TrackIDMapper()
        let bridge = MusicAppTestAccess()
        let musicKitTracks = [
            makeTrack(id: "MK-CLUTCH", name: "Immortal", artist: "Clutch", album: "Pure Rock Fury")
        ]
        let appleScriptTracks = [
            makeTrack(id: "AS-CLUTCH", name: "Immortal", artist: "Clutch", album: "Pure Rock Fury")
        ]
        await bridge.setFetchedTracks(appleScriptTracks)

        let mappedCount = try await mapper.refreshMapping(
            musicKitTracks: musicKitTracks,
            identitySource: bridge
        )

        #expect(mappedCount == 1)
        #expect(await bridge.identityScopes() == [[]])
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
            identitySource: bridge,
            testArtists: ["  in flames ", "In Flames"]
        )

        #expect(mappedCount == 1)
        #expect(await bridge.requestedScopes() == [["in flames"]])
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

private actor ScopedTrackMappingScriptClient: MusicAppIdentifying {
    private let scopedTracks: [String: [Track]]
    private var scopes: [[String]] = []

    init(scopedTracks: [String: [Track]]) {
        self.scopedTracks = scopedTracks
    }

    func fetchIdentityMetadata(scopedTo artists: [String]) async throws -> [Track] {
        scopes.append(artists)
        return artists.flatMap { artist in
            scopedTracks.first { key, _ in
                key.localizedCaseInsensitiveCompare(artist) == .orderedSame
            }?.value ?? []
        }
    }

    func requestedScopes() -> [[String]] {
        scopes
    }
}
