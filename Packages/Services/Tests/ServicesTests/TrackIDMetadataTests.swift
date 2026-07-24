import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("TrackIDMapper metadata")
struct TrackIDMetadataTests {
    @Test("Seeded mapping preserves current AppleScript metadata")
    func seededMappingKeepsMetadata() async throws {
        let mapper = TrackIDMapper()
        let musicKitTrack = makeTrack(
            id: "MK1",
            name: "Jóga",
            artist: "Björk",
            album: "Homogenic",
            metadata: .init(
                genre: "Alternative",
                year: 1998
            )
        )
        let appleScriptTrack = makeTrack(
            id: "AS-HEX-1",
            name: "Jóga",
            artist: "Björk",
            album: "Homogenic",
            metadata: .init(
                genre: "Art Pop",
                year: 1997
            )
        )

        await mapper.seedKnownMappings([(
            musicKitTrack: musicKitTrack,
            appleScriptTrack: appleScriptTrack
        )])

        let writeID = await mapper.appleScriptID(forMusicKitID: "MK1")
        let enrichedTrack = try #require(await mapper.trackWithAppleScriptMetadata(for: musicKitTrack))

        #expect(writeID == "AS-HEX-1")
        #expect(enrichedTrack.id == "MK1")
        #expect(enrichedTrack.genre == "Art Pop")
        #expect(enrichedTrack.year == 1997)
        #expect(enrichedTrack.appleScriptID == "AS-HEX-1")
    }

    @Test("Enriched MusicKit track keeps MusicKit ID and stores AppleScript ID")
    func enrichedTrackKeepsPrimaryIDAndStoresAppleScriptID() async throws {
        let mapper = TrackIDMapper()
        let musicKitTrack = makeTrack(
            id: "MK-1",
            name: "Battery",
            artist: "Metallica",
            album: "Master of Puppets"
        )
        let appleScriptTrack = makeTrack(
            id: "AS-1",
            name: "Battery",
            artist: "Metallica",
            album: "Master of Puppets",
            metadata: .init(
                genre: "Thrash Metal",
                year: 1986,
                trackStatus: TrackKind.localOnly.rawValue,
                releaseYear: 1986,
                albumArtist: "Metallica"
            )
        )

        await mapper.refreshMapping(
            musicKitTracks: [musicKitTrack],
            appleScriptTracks: [appleScriptTrack]
        )

        let enrichedTrack = try #require(await mapper.trackWithAppleScriptMetadata(for: musicKitTrack))

        #expect(enrichedTrack.id == "MK-1")
        #expect(enrichedTrack.appleScriptID == "AS-1")
        #expect(enrichedTrack.genre == "Thrash Metal")
        #expect(enrichedTrack.year == 1986)
        #expect(enrichedTrack.trackStatus == TrackKind.localOnly.rawValue)
    }

    @Test("Enrichment keeps MusicKit ID and uses AppleScript writable metadata")
    func enrichmentKeepsMusicKitIDAndUsesAppleScriptMetadata() async throws {
        let mapper = TrackIDMapper()
        let musicKitTrack = makeTrack(
            id: "MK1",
            name: "Foregone Pt. 1",
            artist: "In Flames",
            album: "Foregone",
            metadata: .init(releaseYear: 2023)
        )
        let appleScriptTrack = makeTrack(
            id: "AS-HEX-1",
            name: "Foregone Pt. 1",
            artist: "In Flames",
            album: "Foregone",
            metadata: .init(
                genre: "Melodic Death Metal",
                year: 2021,
                trackStatus: "subscription",
                releaseYear: 2023,
                albumArtist: "In Flames"
            )
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
