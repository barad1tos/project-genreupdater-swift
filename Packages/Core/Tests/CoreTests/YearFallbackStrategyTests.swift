import Foundation
import Testing
@testable import Core

// MARK: - YearFallbackStrategy Tests

@Suite("YearFallbackStrategy — Decision Tree")
struct YearFallbackStrategyTests {

    let strategy = YearFallbackStrategy()

    // MARK: - Helpers

    private func makeTrack(
        year: Int? = nil,
        dateAdded: Date? = nil,
        album: String = "Test Album"
    ) -> Track {
        Track(
            id: "test-1",
            name: "Test",
            artist: "Artist",
            album: album,
            year: year,
            dateAdded: dateAdded
        )
    }

    private func makeContext(
        existingYear: Int? = nil,
        isDefinitive: Bool = false,
        bestScore: Int = 80,
        bestYear: Int? = 2000,
        albumTypeInfo: AlbumTypeInfo? = nil,
        verificationAttempts: Int = 0,
        track: Track? = nil
    ) -> FallbackContext {
        FallbackContext(
            scoredReleases: [],
            existingYear: existingYear,
            track: track ?? makeTrack(year: existingYear),
            albumTracks: [],
            isDefinitive: isDefinitive,
            bestScore: bestScore,
            bestYear: bestYear,
            albumTypeInfo: albumTypeInfo,
            verificationAttempts: verificationAttempts
        )
    }

    // MARK: - Disabled Fallback

    @Test("Disabled fallback returns noAction")
    func disabledFallback() {
        var config = FallbackConfig()
        config.enabled = false
        let s = YearFallbackStrategy(config: config)
        let context = makeContext(bestScore: 90, bestYear: 2000)
        let decision = s.decide(context)
        guard case .noAction = decision else {
            Issue.record("Expected .noAction, got \(decision)")
            return
        }
    }

    // MARK: - No Candidates

    @Test("No best year returns noAction")
    func noBestYear() {
        let context = makeContext(bestScore: 0, bestYear: nil)
        let decision = strategy.decide(context)
        guard case .noAction = decision else {
            Issue.record("Expected .noAction, got \(decision)")
            return
        }
    }

    @Test("Zero best score returns noAction")
    func zeroBestScore() {
        let context = makeContext(bestScore: 0, bestYear: 2000)
        let decision = strategy.decide(context)
        guard case .noAction = decision else {
            Issue.record("Expected .noAction, got \(decision)")
            return
        }
    }

    // MARK: - Rule 1: Definitive API Result

    @Test("Definitive result uses API year")
    func definitiveResult() {
        let context = makeContext(
            isDefinitive: true,
            bestScore: 95,
            bestYear: 2005
        )
        let decision = strategy.decide(context)
        guard case let .useAPIYear(year, confidence) = decision else {
            Issue.record("Expected .useAPIYear, got \(decision)")
            return
        }
        #expect(year == 2005)
        #expect(confidence == 95)
    }

    // MARK: - Rule 2: Absurd Existing Year

    @Test("Absurd existing year uses API year")
    func absurdExistingYear() {
        let context = makeContext(
            existingYear: 1850,
            bestScore: 80,
            bestYear: 2000
        )
        let decision = strategy.decide(context)
        guard case let .useAPIYear(year, _) = decision else {
            Issue.record("Expected .useAPIYear, got \(decision)")
            return
        }
        #expect(year == 2000)
    }

    // MARK: - Rule 3: Existing Matches API

    @Test("Existing matches API keeps existing")
    func existingMatchesAPI() {
        let context = makeContext(
            existingYear: 2000,
            bestScore: 80,
            bestYear: 2000
        )
        let decision = strategy.decide(context)
        guard case .keepExisting = decision else {
            Issue.record("Expected .keepExisting, got \(decision)")
            return
        }
    }

    // MARK: - Rule 4: Low Confidence

    @Test("Low confidence escalates to verification")
    func lowConfidenceEscalates() {
        let context = makeContext(
            existingYear: 2001,
            bestScore: 50,
            bestYear: 2000
        )
        let decision = strategy.decide(context)
        guard case .escalateToVerification = decision else {
            Issue.record(
                "Expected .escalateToVerification, got \(decision)"
            )
            return
        }
    }

    @Test("Low confidence with max attempts returns noAction")
    func lowConfidenceMaxAttempts() {
        let context = makeContext(
            existingYear: 2001,
            bestScore: 50,
            bestYear: 2000,
            verificationAttempts: 3
        )
        let decision = strategy.decide(context)
        guard case .noAction = decision else {
            Issue.record("Expected .noAction, got \(decision)")
            return
        }
    }

    // MARK: - Rule 5: Fresh Album

    @Test("Fresh album uses API year")
    func freshAlbumUsesAPI() {
        let recentDate = Calendar.current.date(
            byAdding: .month, value: -3, to: Date()
        )!
        let track = makeTrack(
            year: 2001,
            dateAdded: recentDate
        )
        let context = makeContext(
            existingYear: 2001,
            bestScore: 80,
            bestYear: 2000,
            track: track
        )
        let decision = strategy.decide(context)
        guard case let .useAPIYear(year, _) = decision else {
            Issue.record("Expected .useAPIYear, got \(decision)")
            return
        }
        #expect(year == 2000)
    }

    @Test("Old album does NOT trigger fresh rule")
    func oldAlbumNotFresh() {
        let oldDate = Calendar.current.date(
            byAdding: .year, value: -3, to: Date()
        )!
        let track = makeTrack(
            year: 2001,
            dateAdded: oldDate
        )
        // existingYear=2001, bestYear=2002 (diff=1, <= threshold=5)
        // Not fresh, not special, diff not dramatic → default useAPIYear
        let context = makeContext(
            existingYear: 2001,
            bestScore: 80,
            bestYear: 2002,
            track: track
        )
        let decision = strategy.decide(context)
        // Should still use API year via default path (not rule 5)
        guard case .useAPIYear = decision else {
            Issue.record("Expected .useAPIYear, got \(decision)")
            return
        }
    }

    // MARK: - Rule 6: No Existing Year

    @Test("No existing year uses API year")
    func noExistingYear() {
        let context = makeContext(
            existingYear: nil,
            bestScore: 80,
            bestYear: 1999
        )
        let decision = strategy.decide(context)
        guard case let .useAPIYear(year, _) = decision else {
            Issue.record("Expected .useAPIYear, got \(decision)")
            return
        }
        #expect(year == 1999)
    }

    // MARK: - Rule 7: Special Album Type

    @Test("Special album type marks and skips")
    func specialAlbumSkips() {
        let albumInfo = AlbumTypeInfo(
            albumType: .compilation,
            detectedPattern: "greatest hits",
            strategy: .markAndSkip
        )
        let context = makeContext(
            existingYear: 2000,
            bestScore: 80,
            bestYear: 2005,
            albumTypeInfo: albumInfo
        )
        let decision = strategy.decide(context)
        guard case let .markAndSkip(reason) = decision else {
            Issue.record("Expected .markAndSkip, got \(decision)")
            return
        }
        #expect(reason.contains("compilation"))
        #expect(reason.contains("greatest hits"))
    }

    @Test("Reissue with markAndUpdate does NOT trigger rule 7")
    func reissueNotSkipped() {
        let albumInfo = AlbumTypeInfo(
            albumType: .reissue,
            detectedPattern: "remastered",
            strategy: .markAndUpdate
        )
        // existingYear=2000, bestYear=2002, diff=2 <= threshold=5
        // → falls through to default useAPIYear
        let context = makeContext(
            existingYear: 2000,
            bestScore: 80,
            bestYear: 2002,
            albumTypeInfo: albumInfo
        )
        let decision = strategy.decide(context)
        guard case .useAPIYear = decision else {
            Issue.record("Expected .useAPIYear, got \(decision)")
            return
        }
    }

    // MARK: - Rule 8: Dramatic Year Change

    @Test("Dramatic year change escalates")
    func dramaticChangeEscalates() {
        let context = makeContext(
            existingYear: 2000,
            bestScore: 80,
            bestYear: 2020
        )
        let decision = strategy.decide(context)
        guard case let .escalateToVerification(reason) = decision else {
            Issue.record(
                "Expected .escalateToVerification, got \(decision)"
            )
            return
        }
        #expect(reason.contains("2000"))
        #expect(reason.contains("2020"))
    }

    @Test("Dramatic change with max attempts returns noAction")
    func dramaticChangeMaxAttempts() {
        let context = makeContext(
            existingYear: 2000,
            bestScore: 80,
            bestYear: 2020,
            verificationAttempts: 3
        )
        let decision = strategy.decide(context)
        guard case .noAction = decision else {
            Issue.record("Expected .noAction, got \(decision)")
            return
        }
    }

    @Test("Small year diff within threshold uses API year")
    func smallDiffUsesAPI() {
        let context = makeContext(
            existingYear: 2000,
            bestScore: 80,
            bestYear: 2003
        )
        let decision = strategy.decide(context)
        guard case let .useAPIYear(year, _) = decision else {
            Issue.record("Expected .useAPIYear, got \(decision)")
            return
        }
        #expect(year == 2003)
    }

    // MARK: - Custom Config

    @Test("Custom trust threshold changes behavior")
    func customTrustThreshold() {
        var fallbackConfig = FallbackConfig()
        fallbackConfig.trustAPIScoreThreshold = 90
        let s = YearFallbackStrategy(config: fallbackConfig)

        // Score 80 is below threshold 90 → escalate
        let context = makeContext(
            existingYear: 2001,
            bestScore: 80,
            bestYear: 2000
        )
        let decision = s.decide(context)
        guard case .escalateToVerification = decision else {
            Issue.record(
                "Expected .escalateToVerification, got \(decision)"
            )
            return
        }
    }

    @Test("Custom year difference threshold")
    func customYearDiffThreshold() {
        var fallbackConfig = FallbackConfig()
        fallbackConfig.yearDifferenceThreshold = 2
        let s = YearFallbackStrategy(config: fallbackConfig)

        // Diff=3 > threshold=2 → escalate
        let context = makeContext(
            existingYear: 2000,
            bestScore: 80,
            bestYear: 2003
        )
        let decision = s.decide(context)
        guard case .escalateToVerification = decision else {
            Issue.record(
                "Expected .escalateToVerification, got \(decision)"
            )
            return
        }
    }

    // MARK: - Priority Order

    @Test("Definitive overrides all other rules")
    func definitiveOverridesAll() {
        // Definitive + absurd existing + low confidence
        let context = makeContext(
            existingYear: 1800,
            isDefinitive: true,
            bestScore: 50,
            bestYear: 2000
        )
        let decision = strategy.decide(context)
        guard case .useAPIYear = decision else {
            Issue.record("Expected .useAPIYear, got \(decision)")
            return
        }
    }

    @Test("Absurd year takes priority over existing match")
    func absurdOverridesMatch() {
        // existingYear=1800 is absurd (< 1900)
        // bestYear=1800 matches existing, but absurd check is first
        let context = makeContext(
            existingYear: 1800,
            bestScore: 80,
            bestYear: 1800
        )
        let decision = strategy.decide(context)
        // Rule 2 (absurd) fires before Rule 3 (match)
        guard case .useAPIYear = decision else {
            Issue.record("Expected .useAPIYear, got \(decision)")
            return
        }
    }
}
