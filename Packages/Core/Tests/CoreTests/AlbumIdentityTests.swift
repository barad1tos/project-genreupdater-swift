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

    @Test("uses explicit featured artist prefix when album artist is absent")
    func usesExplicitFeaturedArtistPrefixWhenAlbumArtistIsAbsent() {
        let track = Track(
            id: "1",
            name: "Get Lucky",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories"
        )

        let identity = AlbumIdentity(track: track)

        #expect(identity.artist == "Daft Punk")
        #expect(identity.key == "daft punk\u{1F}random access memories")
    }

    @Test("keeps ampersand artist canonical when album artist is absent")
    func keepsAmpersandArtistCanonicalWhenAlbumArtistIsAbsent() {
        let track = Track(
            id: "1",
            name: "Get Lucky",
            artist: "Daft Punk & Pharrell Williams",
            album: "Random Access Memories"
        )

        let identity = AlbumIdentity(track: track)

        #expect(identity.artist == "Daft Punk & Pharrell Williams")
        #expect(identity.key == "daft punk & pharrell williams\u{1F}random access memories")
    }

    @Test("keeps legal ampersand artist names canonical")
    func keepsLegalAmpersandArtistNamesCanonical() {
        let track = Track(
            id: "1",
            name: "The Cave",
            artist: "Mumford & Sons",
            album: "Sigh No More"
        )

        let identity = AlbumIdentity(track: track)

        #expect(identity.artist == "Mumford & Sons")
        #expect(identity.key == "mumford & sons\u{1F}sigh no more")
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

    @Test("keeps extracted artist as lookup alias when album artist is absent")
    func keepsExtractedArtistAsLookupAliasWhenAlbumArtistIsAbsent() {
        let track = Track(
            id: "1",
            name: "Get Lucky",
            artist: "Daft Punk & Pharrell Williams",
            album: "Random Access Memories"
        )

        let keys = AlbumIdentity.lookupKeys(for: track)

        #expect(keys == [
            "daft punk & pharrell williams\u{1F}random access memories",
            "daft punk\u{1F}random access memories",
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
