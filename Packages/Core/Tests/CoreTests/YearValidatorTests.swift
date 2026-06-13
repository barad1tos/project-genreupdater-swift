import Foundation
import Testing
@testable import Core

// MARK: - YearValidator Tests

@Suite("YearValidator — Year Validation & Cross-Track Analysis")
struct YearValidatorTests {
    let validator = YearValidator()

    // MARK: - validate(year:)

    @Test("Valid year returns .valid")
    func validYear() {
        #expect(validator.validate(year: 2000) == .valid)
        #expect(validator.validate(year: 1985) == .valid)
        #expect(validator.validate(year: 2024) == .valid)
    }

    @Test("Year before minValidYear returns .absurd")
    func absurdYear() {
        let result = validator.validate(year: 1850)
        guard case .absurd = result else {
            Issue.record("Expected .absurd, got \(result)")
            return
        }
    }

    @Test("Year exactly at minValidYear returns .suspicious (< absurdYearThreshold)")
    func yearAtMinValid() {
        // minValidYear=1900, absurdYearThreshold=1970
        // 1900 is valid but < 1970, so suspicious
        let result = validator.validate(year: 1900)
        guard case .suspicious = result else {
            Issue.record("Expected .suspicious, got \(result)")
            return
        }
    }

    @Test("Future year returns .future")
    func futureYear() {
        let result = validator.validate(year: 2099)
        guard case .future = result else {
            Issue.record("Expected .future, got \(result)")
            return
        }
    }

    @Test("Year below absurdYearThreshold returns .suspicious")
    func suspiciousYear() {
        let result = validator.validate(year: 1965)
        guard case .suspicious = result else {
            Issue.record("Expected .suspicious, got \(result)")
            return
        }
    }

    @Test("Year at absurdYearThreshold returns .valid")
    func yearAtThreshold() {
        // absurdYearThreshold=1970, year 1970 is NOT < 1970
        #expect(validator.validate(year: 1970) == .valid)
    }

    // MARK: - isAbsurd

    @Test("isAbsurd correctly identifies years before minValidYear")
    func isAbsurdCheck() {
        #expect(validator.isAbsurd(1899))
        #expect(validator.isAbsurd(0))
        #expect(validator.isAbsurd(-1))
        #expect(!validator.isAbsurd(1900))
        #expect(!validator.isAbsurd(2000))
    }

    // MARK: - isFuture

    @Test("isFuture identifies years beyond current+1")
    func isFutureCheck() {
        let currentYear = Calendar.current.component(Calendar.Component.year, from: Date())
        #expect(!validator.isFuture(currentYear))
        #expect(!validator.isFuture(currentYear + 1))
        #expect(validator.isFuture(currentYear + 2))
        #expect(validator.isFuture(2099))
    }

    // MARK: - isSuspicious

    @Test("isSuspicious with no artist context")
    func suspiciousNoArtist() {
        #expect(validator.isSuspicious(year: 1960))
        #expect(!validator.isSuspicious(year: 1980))
    }

    @Test("isSuspicious with artist start year")
    func suspiciousWithArtist() {
        // Artist started in 2000, suspicionThresholdYears=10
        // Year 1989 < 2000-10=1990 → suspicious
        #expect(validator.isSuspicious(year: 1989, artistStartYear: 2000))
        // Year 1990 is NOT < 1990 → not suspicious (also 1990 >= 1970)
        #expect(!validator.isSuspicious(year: 1990, artistStartYear: 2000))
        // Year 1995 → not suspicious
        #expect(!validator.isSuspicious(year: 1995, artistStartYear: 2000))
    }

    @Test("isSuspicious — year below absurdYearThreshold always suspicious")
    func suspiciousAlwaysBelowThreshold() {
        // Even with artist start year, below 1970 is always suspicious
        #expect(validator.isSuspicious(year: 1965, artistStartYear: 1960))
    }

    // MARK: - Custom Config

    @Test("Custom config changes thresholds")
    func customConfig() {
        var config = YearLogicConfig()
        config.minValidYear = 1950
        config.absurdYearThreshold = 1980
        config.suspicionThresholdYears = 5
        let customValidator = YearValidator(config: config)

        // 1949 < 1950 → absurd
        #expect(customValidator.isAbsurd(1949))
        // 1950 is valid but < 1980 → suspicious
        #expect(!customValidator.isAbsurd(1950))
        #expect(customValidator.isSuspicious(year: 1950))

        // Artist started 2000, threshold=5 → 1994 < 1995 → suspicious
        #expect(customValidator.isSuspicious(year: 1994, artistStartYear: 2000))
        #expect(!customValidator.isSuspicious(year: 1995, artistStartYear: 2000))
    }

    // MARK: - getDominantYear

    @Test("Dominant year with clear majority")
    func dominantYearClear() {
        let tracks = [
            Track(id: "1", name: "A", artist: "X", album: "Y", year: 2000),
            Track(id: "2", name: "B", artist: "X", album: "Y", year: 2000),
            Track(id: "3", name: "C", artist: "X", album: "Y", year: 2000),
            Track(id: "4", name: "D", artist: "X", album: "Y", year: 2001),
        ]
        let result = validator.getDominantYear(tracks: tracks)
        #expect(result != nil)
        #expect(result?.year == 2000)
        #expect(result?.trackCount == 3)
        #expect(result?.totalTracks == 4)
        #expect(result?.confidence == 0.75)
    }

    @Test("50/50 split returns higher year at 0.5 confidence")
    func evenSplitReturnsHigherYear() {
        // Python parity: >=0.5 confidence passes, tiebreaker picks higher year
        let tracks = [
            Track(id: "1", name: "A", artist: "X", album: "Y", year: 2000),
            Track(id: "2", name: "B", artist: "X", album: "Y", year: 2001),
        ]
        let result = validator.getDominantYear(tracks: tracks)
        #expect(result != nil)
        #expect(result?.year == 2001)
        #expect(result?.confidence == 0.5)
    }

    @Test("Dominant year ignores tracks without year")
    func dominantYearIgnoresNilYears() {
        let tracks = [
            Track(id: "1", name: "A", artist: "X", album: "Y", year: 2000),
            Track(id: "2", name: "B", artist: "X", album: "Y", year: 2000),
            Track(id: "3", name: "C", artist: "X", album: "Y", year: nil),
            Track(id: "4", name: "D", artist: "X", album: "Y", year: nil),
        ]
        let result = validator.getDominantYear(tracks: tracks)
        #expect(result != nil)
        #expect(result?.year == 2000)
        #expect(result?.confidence == 1.0)
        #expect(result?.totalTracks == 2)
    }

    @Test("No dominant year with empty tracks")
    func dominantYearEmpty() {
        let result = validator.getDominantYear(tracks: [])
        #expect(result == nil)
    }

    @Test("No dominant year when all years are nil")
    func dominantYearAllNil() {
        let tracks = [
            Track(id: "1", name: "A", artist: "X", album: "Y", year: nil),
            Track(id: "2", name: "B", artist: "X", album: "Y", year: nil),
        ]
        let result = validator.getDominantYear(tracks: tracks)
        #expect(result == nil)
    }

    @Test("Suspicious dominant year returns nil")
    func dominantYearSuspicious() {
        let tracks = [
            Track(id: "1", name: "A", artist: "X", album: "Y", year: 1960),
            Track(id: "2", name: "B", artist: "X", album: "Y", year: 1960),
            Track(id: "3", name: "C", artist: "X", album: "Y", year: 1960),
        ]
        // Python parity: suspicious years → nil (need API verification)
        let result = validator.getDominantYear(tracks: tracks)
        #expect(result == nil)
    }

    @Test("Single track is dominant (100% confidence)")
    func singleTrackDominant() {
        let tracks = [
            Track(id: "1", name: "A", artist: "X", album: "Y", year: 2020),
        ]
        let result = validator.getDominantYear(tracks: tracks)
        #expect(result != nil)
        #expect(result?.year == 2020)
        #expect(result?.confidence == 1.0)
    }

    // MARK: - getConsensusReleaseYear

    @Test("Consensus when all tracks agree")
    func consensusAllAgree() {
        let tracks = [
            Track(id: "1", name: "A", artist: "X", album: "Y", releaseYear: 2005),
            Track(id: "2", name: "B", artist: "X", album: "Y", releaseYear: 2005),
            Track(id: "3", name: "C", artist: "X", album: "Y", releaseYear: 2005),
        ]
        #expect(validator.getConsensusReleaseYear(tracks: tracks) == 2005)
    }

    @Test("No consensus when tracks disagree")
    func consensusDisagree() {
        let tracks = [
            Track(id: "1", name: "A", artist: "X", album: "Y", releaseYear: 2005),
            Track(id: "2", name: "B", artist: "X", album: "Y", releaseYear: 2006),
        ]
        #expect(validator.getConsensusReleaseYear(tracks: tracks) == nil)
    }

    @Test("No consensus with empty tracks")
    func consensusEmpty() {
        #expect(validator.getConsensusReleaseYear(tracks: []) == nil)
    }

    @Test("No consensus when all releaseYears are nil")
    func consensusAllNil() {
        let tracks = [
            Track(id: "1", name: "A", artist: "X", album: "Y", releaseYear: nil),
            Track(id: "2", name: "B", artist: "X", album: "Y", releaseYear: nil),
        ]
        #expect(validator.getConsensusReleaseYear(tracks: tracks) == nil)
    }

    @Test("Consensus ignores tracks with nil releaseYear")
    func consensusIgnoresNil() {
        let tracks = [
            Track(id: "1", name: "A", artist: "X", album: "Y", releaseYear: 2010),
            Track(id: "2", name: "B", artist: "X", album: "Y", releaseYear: nil),
            Track(id: "3", name: "C", artist: "X", album: "Y", releaseYear: 2010),
        ]
        #expect(validator.getConsensusReleaseYear(tracks: tracks) == 2010)
    }
}

// MARK: - Year Parity & Suspicious Year Tests

extension YearValidatorTests {
    // MARK: - checkYearParity

    @Test("Parity detected when top two years are tied")
    func parityDetected() {
        let counts: [Int: Int] = [2000: 3, 2001: 3]
        #expect(validator.checkYearParity(yearCounts: counts))
    }

    @Test("Parity detected within threshold (diff=1)")
    func parityWithinThreshold() {
        let counts: [Int: Int] = [2000: 4, 2001: 3]
        #expect(validator.checkYearParity(yearCounts: counts))
    }

    @Test("No parity when clear winner (diff=2)")
    func noParityClearWinner() {
        let counts: [Int: Int] = [2000: 5, 2001: 3]
        #expect(!validator.checkYearParity(yearCounts: counts))
    }

    @Test("No parity with single year")
    func noParitySingleYear() {
        let counts = [2000: 5]
        #expect(!validator.checkYearParity(yearCounts: counts))
    }

    @Test("Below 50% confidence returns nil from getDominantYear")
    func belowHalfConfidenceReturnsNil() {
        // 3 years, best has 2/5 = 40% < 50% → nil
        let tracks = [
            Track(id: "1", name: "A", artist: "X", album: "Y", year: 2020),
            Track(id: "2", name: "B", artist: "X", album: "Y", year: 2020),
            Track(id: "3", name: "C", artist: "X", album: "Y", year: 2019),
            Track(id: "4", name: "D", artist: "X", album: "Y", year: 2018),
            Track(id: "5", name: "E", artist: "X", album: "Y", year: 2018),
        ]
        #expect(validator.getDominantYear(tracks: tracks) == nil)
    }

    // MARK: - isYearSuspiciouslyOld

    @Test("Year is suspiciously old vs dateAdded")
    func suspiciouslyOld() throws {
        // Year 2001, tracks added in 2025 → gap=24 > threshold=10
        let date2025 = try #require(Calendar.current.date(
            from: DateComponents(year: 2025, month: 6, day: 1)
        ))
        let tracks = [
            Track(
                id: "1", name: "A", artist: "X", album: "Y",
                year: 2001, dateAdded: date2025
            ),
        ]
        #expect(validator.isYearSuspiciouslyOld(year: 2001, tracks: tracks))
    }

    @Test("Year is NOT suspiciously old when gap within threshold")
    func notSuspiciouslyOld() throws {
        // Year 2015, tracks added in 2020 → gap=5 <= threshold=10
        let date2020 = try #require(Calendar.current.date(
            from: DateComponents(year: 2020, month: 6, day: 1)
        ))
        let tracks = [
            Track(
                id: "1", name: "A", artist: "X", album: "Y",
                year: 2015, dateAdded: date2020
            ),
        ]
        #expect(!validator.isYearSuspiciouslyOld(year: 2015, tracks: tracks))
    }

    @Test("Year NOT suspiciously old when no dateAdded")
    func notSuspiciousNoDate() {
        let tracks = [
            Track(id: "1", name: "A", artist: "X", album: "Y", year: 2001),
        ]
        #expect(!validator.isYearSuspiciouslyOld(year: 2001, tracks: tracks))
    }

    @Test("Suspiciously old year returns nil from getDominantYear")
    func suspiciousOldMarksDominant() throws {
        let date2025 = try #require(Calendar.current.date(
            from: DateComponents(year: 2025, month: 6, day: 1)
        ))
        let tracks = [
            Track(
                id: "1", name: "A", artist: "X", album: "Y",
                year: 2001, dateAdded: date2025
            ),
            Track(
                id: "2", name: "B", artist: "X", album: "Y",
                year: 2001, dateAdded: date2025
            ),
        ]
        // Python parity: suspiciously old → nil (need API verification)
        let result = validator.getDominantYear(tracks: tracks)
        #expect(result == nil)
    }

    // MARK: - getEarliestTrackAddedYear

    @Test("Earliest track added year found")
    func earliestAdded() throws {
        let date2020 = try #require(Calendar.current.date(
            from: DateComponents(year: 2020, month: 3, day: 1)
        ))
        let date2023 = try #require(Calendar.current.date(
            from: DateComponents(year: 2023, month: 6, day: 1)
        ))
        let tracks = [
            Track(
                id: "1", name: "A", artist: "X", album: "Y",
                dateAdded: date2023
            ),
            Track(
                id: "2", name: "B", artist: "X", album: "Y",
                dateAdded: date2020
            ),
        ]
        #expect(validator.getEarliestTrackAddedYear(tracks: tracks) == 2020)
    }

    @Test("Earliest track added year nil when no dates")
    func earliestAddedNil() {
        let tracks = [
            Track(id: "1", name: "A", artist: "X", album: "Y"),
        ]
        #expect(validator.getEarliestTrackAddedYear(tracks: tracks) == nil)
    }

    // MARK: - checkReleaseYearInconsistency

    @Test("Detects release year inconsistency")
    func releaseYearInconsistency() {
        // All tracks year=2000, but release years differ
        let tracks = [
            Track(
                id: "1", name: "A", artist: "X", album: "Y",
                year: 2000, releaseYear: 2000
            ),
            Track(
                id: "2", name: "B", artist: "X", album: "Y",
                year: 2000, releaseYear: 2005
            ),
        ]
        #expect(validator.checkReleaseYearInconsistency(tracks: tracks) == 2000)
    }

    @Test("No inconsistency when years differ")
    func noInconsistencyDiffYears() {
        let tracks = [
            Track(
                id: "1", name: "A", artist: "X", album: "Y",
                year: 2000, releaseYear: 2000
            ),
            Track(
                id: "2", name: "B", artist: "X", album: "Y",
                year: 2001, releaseYear: 2005
            ),
        ]
        #expect(validator.checkReleaseYearInconsistency(tracks: tracks) == nil)
    }

    @Test("No inconsistency when release years agree")
    func noInconsistencyReleaseAgree() {
        let tracks = [
            Track(
                id: "1", name: "A", artist: "X", album: "Y",
                year: 2000, releaseYear: 2000
            ),
            Track(
                id: "2", name: "B", artist: "X", album: "Y",
                year: 2000, releaseYear: 2000
            ),
        ]
        #expect(validator.checkReleaseYearInconsistency(tracks: tracks) == nil)
    }

    @Test("Release year inconsistency prioritized in getDominantYear")
    func releaseInconsistencyInDominant() {
        let tracks = [
            Track(
                id: "1", name: "A", artist: "X", album: "Y",
                year: 2000, releaseYear: 2000
            ),
            Track(
                id: "2", name: "B", artist: "X", album: "Y",
                year: 2000, releaseYear: 2010
            ),
            Track(
                id: "3", name: "C", artist: "X", album: "Y",
                year: 2000, releaseYear: 2005
            ),
        ]
        let result = validator.getDominantYear(tracks: tracks)
        #expect(result != nil)
        #expect(result?.year == 2000)
        #expect(result?.confidence == 1.0)
        #expect(result?.isSuspicious == false)
    }
}
