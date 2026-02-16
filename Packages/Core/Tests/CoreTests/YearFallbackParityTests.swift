import Foundation
import Testing
@testable import Core

// MARK: - Year Fallback Parity Tests

@Suite("Year Fallback Parity — Python reference fixtures")
struct YearFallbackParityTests {

    let strategy = YearFallbackStrategy()

    @Test("Fallback decision matches Python",
          arguments: try! loadFallbackFixtures())
    func fallbackDecision(fixture: FallbackFixtureCase) {
        let ctx = fixture.context
        let dummyTrack = Track(
            id: "test",
            name: "Test",
            artist: "Test Artist",
            album: "Test Album",
            // Use distant past to avoid triggering "fresh album" rule
            dateAdded: Date.distantPast
        )
        let albumTypeInfo = mapAlbumType(ctx.albumType)

        let context = FallbackContext(
            scoredReleases: [],
            existingYear: ctx.existingYear,
            track: dummyTrack,
            albumTracks: [dummyTrack],
            isDefinitive: ctx.isDefinitive,
            bestScore: ctx.bestScore,
            bestYear: ctx.bestYear,
            albumTypeInfo: albumTypeInfo,
            verificationAttempts: ctx.verificationAttempts
        )

        let decision = strategy.decide(context)
        let decisionStr = FixtureHelpers.decisionType(decision)

        #expect(
            decisionStr == fixture.expected.decision,
            "[\(fixture.id)] decision: got \(decisionStr), expected \(fixture.expected.decision)"
        )
    }
}

// MARK: - Helpers

private func loadFallbackFixtures() throws -> [FallbackFixtureCase] {
    try FixtureLoader.load("year_fallback_reference")
}

private func mapAlbumType(_ typeStr: String) -> AlbumTypeInfo? {
    switch typeStr {
    case "normal":
        nil
    case "compilation":
        AlbumTypeInfo(
            albumType: .compilation,
            detectedPattern: "compilation",
            strategy: .markAndSkip
        )
    case "reissue":
        AlbumTypeInfo(
            albumType: .reissue,
            detectedPattern: "reissue",
            strategy: .markAndSkip
        )
    case "special":
        AlbumTypeInfo(
            albumType: .special,
            detectedPattern: "special",
            strategy: .markAndSkip
        )
    default:
        nil
    }
}
