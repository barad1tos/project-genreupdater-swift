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
        let v = YearValidator(config: config)

        // 1949 < 1950 → absurd
        #expect(v.isAbsurd(1949))
        // 1950 is valid but < 1980 → suspicious
        #expect(!v.isAbsurd(1950))
        #expect(v.isSuspicious(year: 1950))

        // Artist started 2000, threshold=5 → 1994 < 1995 → suspicious
        #expect(v.isSuspicious(year: 1994, artistStartYear: 2000))
        #expect(!v.isSuspicious(year: 1995, artistStartYear: 2000))
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

    @Test("No dominant year when evenly split")
    func noDominantYear() {
        let tracks = [
            Track(id: "1", name: "A", artist: "X", album: "Y", year: 2000),
            Track(id: "2", name: "B", artist: "X", album: "Y", year: 2001),
        ]
        let result = validator.getDominantYear(tracks: tracks)
        #expect(result == nil)
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

    @Test("Dominant year marks suspicious years")
    func dominantYearSuspicious() {
        let tracks = [
            Track(id: "1", name: "A", artist: "X", album: "Y", year: 1960),
            Track(id: "2", name: "B", artist: "X", album: "Y", year: 1960),
            Track(id: "3", name: "C", artist: "X", album: "Y", year: 1960),
        ]
        let result = validator.getDominantYear(tracks: tracks)
        #expect(result?.isSuspicious == true)
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
