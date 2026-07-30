import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("TrackIDMapper fallback matching")
struct TrackIDFallbackTests {
    @Test("Album artist fallback maps variant track artists")
    func albumArtistFallbackMapsVariantTrackArtists() async throws {
        let mapper = TrackIDMapper()
        let musicKitTrack = makeTrack(
            id: "MK1",
            name: "Immortal",
            artist: "Clutch feat. Leslie West",
            album: "Pure Rock Fury",
            metadata: .init(albumArtist: "Clutch")
        )
        let appleScriptTrack = makeTrack(
            id: "AS-HEX-1",
            name: "Immortal",
            artist: "Clutch",
            album: "Pure Rock Fury",
            metadata: .init(
                year: 2001,
                albumArtist: "Clutch"
            )
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
            metadata: .init(albumArtist: "Various Artists")
        )
        let appleScriptTracks = [
            makeTrack(
                id: "AS-FIRST",
                name: "Intro",
                artist: "Performer One",
                album: "Compilation",
                metadata: .init(albumArtist: "Various Artists")
            ),
            makeTrack(
                id: "AS-SECOND",
                name: "Intro",
                artist: "Performer Two",
                album: "Compilation",
                metadata: .init(albumArtist: "Various Artists")
            )
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

    @Test("Album mismatch falls back to a unique name+artist match")
    func albumMismatchFallbackMapsUniqueNameArtist() async throws {
        let mapper = TrackIDMapper()
        // MusicKit indexes the recording under its single album; AppleScript (the
        // live library, the write source of truth) has the same recording on a
        // later album. The (name, artist, album) key cannot bridge them.
        let musicKitTrack = makeTrack(
            id: "MK-1",
            name: "Дивна любов",
            artist: "паліндром",
            album: "Дивна любов - Single"
        )
        let appleScriptTrack = makeTrack(
            id: "AS-102090",
            name: "Дивна любов",
            artist: "паліндром",
            album: "Декілька пісень невизначеності (ч.1)"
        )

        await mapper.refreshMapping(
            musicKitTracks: [musicKitTrack],
            appleScriptTracks: [appleScriptTrack]
        )

        let writeID = await mapper.appleScriptID(forMusicKitID: "MK-1")
        #expect(writeID == "AS-102090")
        let enriched = try #require(await mapper.trackWithAppleScriptMetadata(for: musicKitTrack))
        #expect(enriched.album == "Декілька пісень невизначеності (ч.1)")
    }

    @Test("Album mismatch with ambiguous name+artist is not mapped")
    func albumMismatchAmbiguousNameArtistIsNotMapped() async {
        let mapper = TrackIDMapper()
        let musicKitTrack = makeTrack(
            id: "MK-1",
            name: "Дивна любов",
            artist: "паліндром",
            album: "Дивна любов - Single"
        )
        // Two distinct AppleScript recordings share name+artist on different albums,
        // so the album-agnostic fallback must stay conservative and not guess.
        let appleScriptTracks = [
            makeTrack(id: "AS-A", name: "Дивна любов", artist: "паліндром", album: "Альбом А"),
            makeTrack(id: "AS-B", name: "Дивна любов", artist: "паліндром", album: "Альбом Б")
        ]

        await mapper.refreshMapping(
            musicKitTracks: [musicKitTrack],
            appleScriptTracks: appleScriptTracks
        )

        #expect(await mapper.appleScriptID(forMusicKitID: "MK-1") == nil)
    }

    @Test("Fallback does not reuse an AppleScript track already claimed by the primary pass")
    func fallbackDoesNotReuseClaimedAppleScriptTrack() async {
        let mapper = TrackIDMapper()
        // MusicKit holds two distinct recordings (studio + live) of one song; the
        // live one is absent from AppleScript. The studio one maps exactly, and the
        // live one must not fall back onto the studio track and overwrite it.
        let musicKitTracks = [
            makeTrack(id: "MK-studio", name: "Song", artist: "Band", album: "Studio"),
            makeTrack(id: "MK-live", name: "Song", artist: "Band", album: "Live")
        ]
        let appleScriptTracks = [
            makeTrack(id: "AS-studio", name: "Song", artist: "Band", album: "Studio")
        ]

        await mapper.refreshMapping(
            musicKitTracks: musicKitTracks,
            appleScriptTracks: appleScriptTracks
        )

        #expect(await mapper.appleScriptID(forMusicKitID: "MK-studio") == "AS-studio")
        #expect(await mapper.appleScriptID(forMusicKitID: "MK-live") == nil)
    }
}
