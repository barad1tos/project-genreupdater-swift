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
        let customStrategy = YearFallbackStrategy(config: config)
        let context = makeContext(bestScore: 90, bestYear: 2000)
        let decision = customStrategy.decide(context)
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

    // MARK: - Rule 2: No Candidates

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

    @Test("No candidates with existing year keeps existing")
    func noCandidatesKeepsExisting() {
        let context = makeContext(
            existingYear: 1999,
            bestScore: 0,
            bestYear: nil
        )
        let decision = strategy.decide(context)
        guard case .keepExisting = decision else {
            Issue.record("Expected .keepExisting, got \(decision)")
            return
        }
    }

    // MARK: - Rule 3: Special Album Type

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

    @Test("Reissue with markAndUpdate falls through to year rules")
    func reissueNotSkipped() {
        let albumInfo = AlbumTypeInfo(
            albumType: .reissue,
            detectedPattern: "remastered",
            strategy: .markAndUpdate
        )
        // existingYear=2000, bestYear=2002, diff=2 ≤ threshold=5
        // Not markAndSkip → falls through → Rule 5: close diff → keepExisting
        let context = makeContext(
            existingYear: 2000,
            bestScore: 80,
            bestYear: 2002,
            albumTypeInfo: albumInfo
        )
        let decision = strategy.decide(context)
        guard case .keepExisting = decision else {
            Issue.record("Expected .keepExisting, got \(decision)")
            return
        }
    }

    // MARK: - Rule 4: Max Verification Attempts

    @Test("Max verification attempts uses API year")
    func maxAttemptsUsesAPI() {
        let context = makeContext(
            existingYear: 2001,
            bestScore: 50,
            bestYear: 2000,
            verificationAttempts: 3
        )
        let decision = strategy.decide(context)
        guard case let .useAPIYear(year, _) = decision else {
            Issue.record("Expected .useAPIYear, got \(decision)")
            return
        }
        #expect(year == 2000)
    }

    // MARK: - Rules 5-7: Has Existing Year

    @Test("Close year difference keeps existing (Rule 5)")
    func closeDiffKeepsExisting() {
        // existingYear=2000, bestYear=2003, diff=3 ≤ threshold=5
        let context = makeContext(
            existingYear: 2000,
            bestScore: 80,
            bestYear: 2003
        )
        let decision = strategy.decide(context)
        guard case .keepExisting = decision else {
            Issue.record("Expected .keepExisting, got \(decision)")
            return
        }
    }

    @Test("Existing matches API keeps existing (Rule 5, diff=0)")
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

    @Test("Large diff + low confidence keeps existing (Rule 6)")
    func largeDiffLowConfidenceKeepsExisting() {
        // diff=10 > threshold=5, score=50 < trustThreshold=70
        let context = makeContext(
            existingYear: 2000,
            bestScore: 50,
            bestYear: 2010
        )
        let decision = strategy.decide(context)
        guard case .keepExisting = decision else {
            Issue.record("Expected .keepExisting, got \(decision)")
            return
        }
    }

    @Test("Large diff + high confidence uses API year (Rule 7)")
    func largeDiffHighConfidenceUsesAPI() {
        // diff=20 > threshold=5, score=80 >= trustThreshold=70
        let context = makeContext(
            existingYear: 2000,
            bestScore: 80,
            bestYear: 2020
        )
        let decision = strategy.decide(context)
        guard case let .useAPIYear(year, confidence) = decision else {
            Issue.record("Expected .useAPIYear, got \(decision)")
            return
        }
        #expect(year == 2020)
        #expect(confidence == 80)
    }

    @Test("Very large diff still uses API year if confident (Rule 7)")
    func veryLargeDiffUsesAPI() {
        // existingYear=1850, bestYear=2000, diff=150 > 5, score=80 >= 70
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

    // MARK: - Rules 8-9: No Existing Year

    @Test("No existing year + low confidence escalates (Rule 8)")
    func noExistingLowConfidenceEscalates() {
        let context = makeContext(
            existingYear: nil,
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

    @Test("No existing year + high confidence uses API year (Rule 9)")
    func noExistingHighConfidenceUsesAPI() {
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
}

// MARK: - Custom Config

extension YearFallbackStrategyTests {
    @Test("Custom trust threshold changes escalation behavior")
    func customTrustThreshold() {
        var fallbackConfig = FallbackConfig()
        fallbackConfig.trustAPIScoreThreshold = 90
        let customStrategy = YearFallbackStrategy(config: fallbackConfig)

        // No existing year, score 80 < threshold 90 → Rule 8: escalate
        let context = makeContext(
            existingYear: nil,
            bestScore: 80,
            bestYear: 2000
        )
        let decision = customStrategy.decide(context)
        guard case .escalateToVerification = decision else {
            Issue.record(
                "Expected .escalateToVerification, got \(decision)"
            )
            return
        }
    }

    @Test("Custom year difference threshold triggers large-diff cascade")
    func customYearDiffThreshold() {
        var fallbackConfig = FallbackConfig()
        fallbackConfig.yearDifferenceThreshold = 2
        let customStrategy = YearFallbackStrategy(config: fallbackConfig)

        // Diff=3 > threshold=2, score=80 >= trustThreshold=70 → Rule 7
        let context = makeContext(
            existingYear: 2000,
            bestScore: 80,
            bestYear: 2003
        )
        let decision = customStrategy.decide(context)
        guard case let .useAPIYear(year, _) = decision else {
            Issue.record(
                "Expected .useAPIYear, got \(decision)"
            )
            return
        }
        #expect(year == 2003)
    }
}

// MARK: - Priority Order

extension YearFallbackStrategyTests {
    @Test("Definitive overrides all other rules")
    func definitiveOverridesAll() {
        // Definitive + existing + low confidence
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

    @Test("Max attempts overrides close-diff keepExisting")
    func maxAttemptsOverridesCloseDiff() {
        // diff=1 ≤ 5 would keepExisting, but maxAttempts fires first
        let context = makeContext(
            existingYear: 2001,
            bestScore: 80,
            bestYear: 2000,
            verificationAttempts: 3
        )
        let decision = strategy.decide(context)
        guard case let .useAPIYear(year, _) = decision else {
            Issue.record("Expected .useAPIYear, got \(decision)")
            return
        }
        #expect(year == 2000)
    }
}
