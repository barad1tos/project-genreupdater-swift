// YearValidator.swift — Year validation and cross-track analysis
// Ported from: year_consistency.py 393 LOC
//
// Pure struct (TDD Decision 9). Validates individual years and
// analyzes cross-track consistency for album-level decisions.

import Foundation

// MARK: - YearValidator

/// Validates years and analyzes cross-track year consistency.
///
/// Validation rules:
/// - Absurd: year < minValidYear (default 1900)
/// - Future: year > currentCalendarYear + 1
/// - Suspicious: year < absurdYearThreshold or before artist started
/// - Valid: passes all checks
///
/// Cross-track analysis:
/// - Dominant year: most common year across album tracks (>50% share)
/// - Consensus release year: all tracks agree on the same releaseYear
public struct YearValidator: Sendable {
    public let config: YearLogicConfig

    public init(config: YearLogicConfig = YearLogicConfig()) {
        self.config = config
    }

    // MARK: - Single Year Validation

    /// Validate a year value against all rules.
    public func validate(year: Int) -> YearValidation {
        if isAbsurd(year) {
            return .absurd(reason: "Year \(year) is before \(config.minValidYear)")
        }
        if isFuture(year) {
            return .future(reason: "Year \(year) is in the future")
        }
        if year < config.absurdYearThreshold {
            return .suspicious(reason: "Year \(year) is before \(config.absurdYearThreshold)")
        }
        return .valid
    }

    /// Whether a year is absurdly old (before recorded music era).
    public func isAbsurd(_ year: Int) -> Bool {
        year < config.minValidYear
    }

    /// Whether a year is in the future (beyond next calendar year).
    public func isFuture(_ year: Int) -> Bool {
        let currentYear = Calendar.current.component(.year, from: Date())
        return year > currentYear + 1
    }

    /// Whether a year is suspicious given context.
    ///
    /// A year is suspicious if:
    /// - It's before the absurd year threshold (default 1970), OR
    /// - It's before the artist's start year minus the suspicion threshold
    public func isSuspicious(year: Int, artistStartYear: Int? = nil) -> Bool {
        if year < config.absurdYearThreshold {
            return true
        }
        if let startYear = artistStartYear {
            return year < startYear - config.suspicionThresholdYears
        }
        return false
    }

    // MARK: - Cross-Track Analysis

    /// Find the dominant year across album tracks.
    ///
    /// Returns the most common year if its share exceeds 50% of tracks
    /// with year data. Returns nil if no year has majority.
    public func getDominantYear(tracks: [Track]) -> DominantYearResult? {
        let tracksWithYear = tracks.compactMap { $0.year }
        guard !tracksWithYear.isEmpty else { return nil }

        var yearCounts: [Int: Int] = [:]
        for year in tracksWithYear {
            yearCounts[year, default: 0] += 1
        }

        guard let (bestYear, bestCount) = yearCounts.max(by: {
            $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key)
        }) else { return nil }

        let confidence = Double(bestCount) / Double(tracksWithYear.count)

        // Require >50% share for a dominant year
        guard confidence > 0.5 else { return nil }

        return DominantYearResult(
            year: bestYear,
            confidence: confidence,
            trackCount: bestCount,
            totalTracks: tracksWithYear.count,
            isSuspicious: isSuspicious(year: bestYear)
        )
    }

    /// Check if all tracks agree on the same release year.
    ///
    /// Returns the consensus year if all tracks with a non-nil releaseYear
    /// share the same value. Returns nil if tracks disagree or no
    /// release years are present.
    public func getConsensusReleaseYear(tracks: [Track]) -> Int? {
        let releaseYears = tracks.compactMap(\.releaseYear)
        guard let first = releaseYears.first else { return nil }

        let allSame = releaseYears.allSatisfy { $0 == first }
        return allSame ? first : nil
    }
}
