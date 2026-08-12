import Testing
@testable import Core

@Suite("YearScorer — Soundtrack Compensation")
struct YearScorerSoundtrackTests {
    @Test("Soundtrack album compensates artist mismatch")
    func soundtrackCompensation() {
        let candidate = ReleaseCandidate(
            artist: "Hans Zimmer",
            album: "Inception (Original Motion Picture Soundtrack)",
            year: 2010,
            source: .musicBrainz,
            releaseType: .soundtrack
        )
        let result = YearScorer().scoreRelease(
            candidate,
            queryArtist: "Various Artists",
            queryAlbum: "Inception (Original Motion Picture Soundtrack)"
        )
        #expect(result.breakdown.soundtrackCompensation == 75)
    }

    @Test("Non-soundtrack does not get compensation")
    func noSoundtrackCompensation() {
        let candidate = ReleaseCandidate(
            artist: "X",
            album: "Album",
            year: 2000,
            source: .musicBrainz
        )
        let result = YearScorer().scoreRelease(candidate, queryArtist: "Y", queryAlbum: "Album")
        #expect(result.breakdown.soundtrackCompensation == 0)
    }

    @Test("Configured soundtrack markers drive compensation")
    func configuredSoundtrackMarkers() {
        let scorer = YearScorer(soundtrackPatterns: ["game score"])
        let candidate = ReleaseCandidate(
            artist: "Composer",
            album: "Journey Game Score",
            year: 2012,
            source: .musicBrainz
        )

        let result = scorer.scoreRelease(
            candidate,
            queryArtist: "Various Artists",
            queryAlbum: "Journey Game Score"
        )

        #expect(result.breakdown.soundtrackCompensation == 75)
    }

    @Test("Empty soundtrack markers disable built-in compensation")
    func emptySoundtrackMarkersDisableCompensation() {
        let scorer = YearScorer(soundtrackPatterns: [])
        let candidate = ReleaseCandidate(
            artist: "Composer",
            album: "Journey Original Score",
            year: 2012,
            source: .musicBrainz
        )

        let result = scorer.scoreRelease(
            candidate,
            queryArtist: "Various Artists",
            queryAlbum: "Journey Original Score"
        )

        #expect(result.breakdown.soundtrackCompensation == 0)
    }
}
