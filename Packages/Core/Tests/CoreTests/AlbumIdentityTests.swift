import Foundation
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

    @Test("splits ampersand artist like Python when album artist is absent")
    func splitsAmpersandArtistWhenAlbumArtistIsAbsent() {
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

    @Test("splits legal ampersand names too — the Python fallback contract")
    func splitsLegalAmpersandNamesPerPythonFallback() {
        // Deliberate full-parity adjudication (slice 15): albumArtist is
        // the shield for legal duo names; a track WITHOUT one takes
        // Python's aggressive split, wart and all.
        let track = Track(
            id: "1",
            name: "The Cave",
            artist: "Mumford & Sons",
            album: "Sigh No More"
        )

        let identity = AlbumIdentity(track: track)

        #expect(identity.artist == "Mumford")
        #expect(identity.key == "mumford\u{1F}sigh no more")
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

    @Test("lookup aliases carry the split and the raw ampersand artist")
    func lookupAliasesCarrySplitAndRawAmpersandArtist() {
        let track = Track(
            id: "1",
            name: "Get Lucky",
            artist: "Daft Punk & Pharrell Williams",
            album: "Random Access Memories"
        )

        let keys = AlbumIdentity.lookupKeys(for: track)

        #expect(keys == [
            "daft punk\u{1F}random access memories",
            "daft punk & pharrell williams\u{1F}random access memories",
        ])
    }

    @Test("the album-artist shield covers lookup aliases too")
    func albumArtistShieldCoversLookupAliases() {
        // A legal duo WITH an album artist must never grow a split alias:
        // "Simon & Garfunkel" querying rows for "Simon" would hit an
        // unrelated artist's cache (PR #162 review, Codex P2).
        let track = Track(
            id: "1",
            name: "The Boxer",
            artist: "Simon & Garfunkel",
            album: "Greatest Hits",
            albumArtist: "Simon & Garfunkel"
        )

        let keys = AlbumIdentity.lookupKeys(for: track)

        #expect(keys == [
            "simon & garfunkel\u{1F}greatest hits",
        ])
    }

    @Test("legacy featuring rows written by the retired splitter stay reachable")
    func legacyFeaturingRowsStayReachable() {
        // The pre-parity splitter cut " featuring " (case-insensitively);
        // rows persisted under its output must remain findable.
        let track = Track(
            id: "1",
            name: "Song",
            artist: "Alpha featuring Beta",
            album: "Album"
        )

        let keys = AlbumIdentity.lookupKeys(for: track)

        #expect(keys.contains("alpha\u{1F}album"))
        #expect(keys.contains("alpha featuring beta\u{1F}album"))
    }

    @Test("legacy case-insensitive feat rows stay reachable")
    func legacyCaseInsensitiveFeatRowsStayReachable() {
        let track = Track(
            id: "1",
            name: "Song",
            artist: "Alpha Feat. Beta",
            album: "Album"
        )

        let keys = AlbumIdentity.lookupKeys(for: track)

        #expect(keys.contains("alpha\u{1F}album"))
        #expect(keys.contains("alpha feat. beta\u{1F}album"))
    }

    @Test("legacy raw-name rows stay reachable through lookup aliases")
    func legacyRawNameRowsStayReachableThroughLookupAliases() {
        // Old cache/pending rows were written under the unsplit name;
        // the alias list keeps them findable after the parity switch.
        let track = Track(
            id: "1",
            name: "The Cave",
            artist: "Mumford & Sons",
            album: "Sigh No More"
        )

        let keys = AlbumIdentity.lookupKeys(for: track)

        #expect(keys == [
            "mumford\u{1F}sigh no more",
            "mumford & sons\u{1F}sigh no more",
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

    @Test("decoding preserves album identity normalization")
    func decodingPreservesAlbumIdentityNormalization() throws {
        let data = Data(
            """
            {"artist":"  Bjork  ","album":"  Debut  "}
            """.utf8
        )

        let identity = try JSONDecoder().decode(AlbumIdentity.self, from: data)

        #expect(identity.artist == "Bjork")
        #expect(identity.album == "Debut")
        #expect(identity.isComplete == true)
    }

    @Test("hashing uses normalized album identity key")
    func hashingUsesNormalizedAlbumIdentityKey() {
        let identities: Set<AlbumIdentity> = [
            AlbumIdentity(artist: "Bjork", album: "Debut"),
            AlbumIdentity(artist: "  bjork  ", album: "  debut  "),
        ]

        #expect(identities.count == 1)
    }
}

/// Python parity: normalize_collaboration_artist (year_utils.py) — the
/// separator LIST ORDER wins (not string position), matching is
/// case-sensitive, split takes the left side. The aggressive " and "/" x "
/// splits ARE the contract; fixtures document them deliberately.
@Suite("Collaboration artist parity — Python reference fixtures")
struct CollaborationArtistParityTests {
    @Test("feat splits to the primary artist")
    func featSplits() {
        #expect(primary("Drake feat. Rihanna") == "Drake")
    }

    @Test("ampersand splits like Python")
    func ampersandSplits() {
        #expect(primary("Daft Punk & Pharrell") == "Daft Punk")
    }

    @Test("a solo artist passes through")
    func soloPassesThrough() {
        #expect(primary("Solo Artist") == "Solo Artist")
    }

    @Test("vs variants split")
    func vsSplits() {
        #expect(primary("A vs. B") == "A")
        #expect(primary("A vs B") == "A")
    }

    @Test("the aggressive and-split is the Python contract")
    func andSplits() {
        #expect(primary("Florence and the Machine") == "Florence")
    }

    @Test("with and x variants split")
    func withAndLowercaseXSplit() {
        #expect(primary("A with B") == "A")
        #expect(primary("A x B") == "A")
        #expect(primary("A X B") == "A")
    }

    @Test("list order outranks string position")
    func listOrderOutranksStringPosition() {
        // " & " precedes " feat. " in the Python list, so it wins even
        // though " feat. " appears earlier in the string.
        #expect(primary("A feat. B & C") == "A feat. B")
    }

    @Test("matching is case-sensitive like Python")
    func matchingIsCaseSensitive() {
        #expect(primary("A FEAT. B") == "A FEAT. B")
        #expect(primary("A And B") == "A And B")
    }

    @Test("featuring is not a Python separator")
    func featuringDoesNotSplit() {
        #expect(primary("A featuring B") == "A featuring B")
    }

    @Test("an empty left side falls back to the whole artist")
    func emptyLeftSideFallsBack() {
        // Deliberate defensive divergence: Python returns "" here.
        #expect(primary(" & Friends") == "& Friends")
    }

    private func primary(_ artist: String) -> String {
        AlbumIdentity.primaryArtist(for: Track(
            id: "T",
            name: "Song",
            artist: artist,
            album: "Album"
        ))
    }
}
