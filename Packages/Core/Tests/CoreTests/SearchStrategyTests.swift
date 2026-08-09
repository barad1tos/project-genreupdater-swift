import Foundation
import Testing
@testable import Core

/// Python parity: detect_search_strategy (search_strategy.py) — detection
/// order soundtrack → Various Artists → unusual brackets → normal, first
/// match wins. These fixtures mirror the Python module's semantics.
@Suite("Search strategy — Python reference fixtures")
struct SearchStrategyTests {
    @Test("A soundtrack album rewrites both sides to the movie name")
    func soundtrackRewritesToMovieName() {
        // The rstrip cases Python's "([-–— set exists for: a dash or an
        // opening paren between the movie name and the pattern falls off.
        let dashed = detect(album: "Dune - Original Score")
        let parenthesized = detect(album: "Interstellar (OST)")

        #expect(dashed.strategy == .soundtrack)
        #expect(dashed.modifiedArtist == "Dune")
        #expect(dashed.modifiedAlbum == "Dune")
        #expect(parenthesized.modifiedArtist == "Interstellar")
    }

    @Test("Multi-pattern albums resolve by list order, deterministically")
    func multiPatternResolvesByListOrder() {
        // Python iterates a frozenset (per-run nondeterministic!); the
        // Swift port is deterministic first-in-list — a documented
        // improvement, not a divergence in any single Python run.
        let info = detect(album: "Inception (Original Motion Picture Soundtrack)")

        #expect(info.strategy == .soundtrack)
        #expect(info.modifiedArtist == "Inception (Original Motion Picture")
    }

    @Test("A pattern at the start flags soundtrack without a rewrite")
    func soundtrackAtStartKeepsQuery() {
        let info = detect(album: "Soundtrack Collection")

        #expect(info.strategy == .soundtrack)
        #expect(info.modifiedArtist == nil)
        #expect(info.modifiedAlbum == nil)
    }

    @Test("Various Artists searches by album only")
    func variousArtistsSearchesAlbumOnly() {
        let english = detect(artist: "Various Artists", album: "Now 42")
        let ukrainian = detect(artist: "Різні виконавці", album: "Збірка")

        #expect(english.strategy == .variousArtists)
        #expect(english.modifiedArtist == nil)
        #expect(english.modifiedAlbum == "Now 42")
        #expect(ukrainian.strategy == .variousArtists)
    }

    @Test("Long bracket content strips from the album")
    func longBracketContentStrips() {
        let info = detect(album: "Sermon [MESSAGE FROM THE CLERGY]")

        #expect(info.strategy == .stripBrackets)
        #expect(info.modifiedAlbum == "Sermon")
        #expect(info.modifiedArtist == "Artist")
    }

    @Test("Short normal tags stay normal")
    func shortNormalTagsStayNormal() {
        #expect(detect(album: "Album [CD1]").strategy == .normal)
        #expect(detect(album: "Album [Deluxe]").strategy == .normal)
        #expect(detect(album: "Album [remaster]").strategy == .normal)
    }

    @Test("A short but uppercase bracket strips")
    func shortUppercaseBracketStrips() {
        let info = detect(album: "Album [LIVE]")

        #expect(info.strategy == .stripBrackets)
        #expect(info.modifiedAlbum == "Album")
    }

    @Test("Soundtrack outranks Various Artists outranks brackets")
    func precedenceOrder() {
        let soundtrackBeatsVA = detect(
            artist: "Various Artists",
            album: "Dune (Original Score) [SPECIAL EDITION BOX]"
        )
        let vaBeatsBrackets = detect(
            artist: "Various Artists",
            album: "Now [SPECIAL EDITION BOX SET]"
        )

        #expect(soundtrackBeatsVA.strategy == .soundtrack)
        #expect(vaBeatsBrackets.strategy == .variousArtists)
    }

    @Test("An empty album is normal")
    func emptyAlbumIsNormal() {
        #expect(detect(album: "").strategy == .normal)
    }

    private func detect(
        artist: String = "Artist",
        album: String
    ) -> SearchStrategyInfo {
        detectSearchStrategy(
            artist: artist,
            album: album,
            soundtrackPatterns: [],
            variousArtistsNames: []
        )
    }
}
