import Foundation
import Testing
@testable import Core

// MARK: - Year Fallback Parity Tests

@Suite("Year Fallback Parity — Python reference fixtures")
struct YearFallbackParityTests {
    let strategy = YearFallbackStrategy()

    @Test("Fallback decision matches Python")
    func fallbackDecision() throws {
        let fixtures: [FallbackFixtureCase] = try loadFallbackFixtures()

        for fixture in fixtures {
            let contextFixture = fixture.context
            let dummyTrack = Track(
                id: "test",
                name: "Test",
                artist: "Test Artist",
                album: "Test Album",
                // Use distant past to avoid triggering "fresh album" rule
                dateAdded: Date.distantPast
            )
            let albumTypeInfo = mapAlbumType(contextFixture.albumType)

            let context = FallbackContext(
                scoredReleases: [],
                existingYear: contextFixture.existingYear,
                track: dummyTrack,
                albumTracks: [dummyTrack],
                isDefinitive: contextFixture.isDefinitive,
                bestScore: contextFixture.bestScore,
                bestYear: contextFixture.bestYear,
                albumTypeInfo: albumTypeInfo,
                verificationAttempts: contextFixture.verificationAttempts
            )

            let decision = strategy.decide(context)
            let decisionStr = FixtureHelpers.decisionType(decision)

            #expect(
                decisionStr == fixture.expected.decision,
                "[\(fixture.id)] decision: got \(decisionStr), expected \(fixture.expected.decision)"
            )
        }
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
