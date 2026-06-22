import Testing
@testable import Core

@Suite("AlbumIdentity")
struct AlbumIdentityTests {
    @Test("uses album artist when present")
    func usesAlbumArtistWhenPresent() {
        let track = Track(
            id: "1",
            name: "Guest Track",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            albumArtist: "Daft Punk"
        )

        let identity = AlbumIdentity(track: track)

        #expect(identity.artist == "Daft Punk")
        #expect(identity.album == "Random Access Memories")
        #expect(identity.key == "daft punk\u{1F}random access memories")
    }

    @Test("extracts main artist when album artist is absent")
    func extractsMainArtistWhenAlbumArtistIsAbsent() {
        let track = Track(
            id: "1",
            name: "Get Lucky",
            artist: "Daft Punk & Pharrell Williams",
            album: "Random Access Memories"
        )

        let identity = AlbumIdentity(track: track)

        #expect(identity.artist == "Daft Punk")
        #expect(identity.key == "daft punk\u{1F}random access memories")
    }

    @Test("includes legacy artist aliases for lookup")
    func includesLegacyArtistAliasesForLookup() {
        let track = Track(
            id: "1",
            name: "Get Lucky",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            albumArtist: "Daft Punk"
        )

        let keys = AlbumIdentity.lookupKeys(for: track)

        #expect(keys == [
            "daft punk\u{1F}random access memories",
            "daft punk feat. pharrell williams\u{1F}random access memories",
        ])
    }

    @Test("keeps solo artist unchanged")
    func keepsSoloArtistUnchanged() {
        let track = Track(
            id: "1",
            name: "American Sleep",
            artist: "Clutch",
            album: "Pure Rock Fury"
        )

        #expect(AlbumIdentity(track: track).artist == "Clutch")
    }

    @Test("normalizes keys without changing display values")
    func normalizesKeysWithoutChangingDisplayValues() {
        let identity = AlbumIdentity(
            artist: "  Bjork  ",
            album: "  Debut  "
        )

        #expect(identity.artist == "Bjork")
        #expect(identity.album == "Debut")
        #expect(identity.key == "bjork\u{1F}debut")
    }
}
