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

    /// Max count difference between top 2 years to consider a tie.
    public static let parityThreshold = 1

    /// Find the dominant year across album tracks.
    ///
    /// Python parity: checks release year inconsistency first,
    /// then majority dominance (with suspicious-old check),
    /// then year parity. Returns nil when API verification needed.
    public func getDominantYear(tracks: [Track]) -> DominantYearResult? {
        let tracksWithYear = tracks.compactMap(\.year)
        guard !tracksWithYear.isEmpty else { return nil }

        var yearCounts: [Int: Int] = [:]
        for year in tracksWithYear {
            yearCounts[year, default: 0] += 1
        }

        guard let (bestYear, bestCount) = yearCounts.max(by: {
            $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key)
        }) else { return nil }

        // Check release year inconsistency: all same year but
        // different release_years → use the consistent track year
        if let consistentYear = checkReleaseYearInconsistency(
            tracks: tracks
        ) {
            return DominantYearResult(
                year: consistentYear,
                confidence: 1.0,
                trackCount: tracksWithYear.count,
                totalTracks: tracksWithYear.count,
                isSuspicious: false
            )
        }

        let confidence = Double(bestCount) / Double(tracksWithYear.count)

        // Require >50% share for a dominant year.
        // Parity (tie between top two years) also returns nil —
        // both cases need API verification.
        guard confidence > 0.5 else {
            return nil
        }

        // Check if year is suspiciously old vs dateAdded
        let suspiciousOld = isYearSuspiciouslyOld(
            year: bestYear, tracks: tracks
        )
        let suspicious = isSuspicious(year: bestYear) || suspiciousOld

        return DominantYearResult(
            year: bestYear,
            confidence: confidence,
            trackCount: bestCount,
            totalTracks: tracksWithYear.count,
            isSuspicious: suspicious
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

    // MARK: - Year Parity

    /// Check if top two years have near-equal counts (tie).
    ///
    /// When parity exists, no single year dominates and API
    /// verification is needed. Ported from `_check_year_parity`.
    public func checkYearParity(yearCounts: [Int: Int]) -> Bool {
        let sorted = yearCounts.sorted { $0.value > $1.value }
        guard sorted.count >= 2 else { return false }

        let diff = sorted[0].value - sorted[1].value
        return diff <= Self.parityThreshold
    }

    // MARK: - Suspiciously Old Year

    /// Check if a year is suspiciously old compared to when tracks
    /// were added to the library.
    ///
    /// Catches cases where tracks have year 2001 but were added in 2025.
    /// Ported from `_is_year_suspiciously_old`.
    public func isYearSuspiciouslyOld(
        year: Int, tracks: [Track]
    ) -> Bool {
        guard let earliestAdded = getEarliestTrackAddedYear(
            tracks: tracks
        ) else {
            return false
        }
        let gap = earliestAdded - year
        return gap > config.suspicionThresholdYears
    }

    /// Extract the earliest year any track was added to the library.
    /// Ported from `get_earliest_track_added_year`.
    public func getEarliestTrackAddedYear(
        tracks: [Track]
    ) -> Int? {
        let years = tracks.compactMap { track -> Int? in
            guard let dateAdded = track.dateAdded else { return nil }
            return Calendar.current.component(.year, from: dateAdded)
        }
        return years.min()
    }

    // MARK: - Release Year Inconsistency

    /// Check if all tracks share the same year but have inconsistent
    /// release years.
    ///
    /// When all tracks agree on `year` but disagree on `releaseYear`,
    /// the consistent track year is preferred.
    /// Ported from `_check_release_year_inconsistency`.
    public func checkReleaseYearInconsistency(
        tracks: [Track]
    ) -> Int? {
        let years = tracks.compactMap(\.year)
        guard !years.isEmpty else { return nil }

        let uniqueYears = Set(years)
        guard uniqueYears.count == 1,
              let consistentYear = uniqueYears.first else {
            return nil
        }

        // Only tracks with a non-nil releaseYear can reveal inconsistency;
        // need at least 2 to compare.
        let releaseYears = tracks.compactMap(\.releaseYear)
        guard releaseYears.count >= 2 else { return nil }

        let uniqueReleaseYears = Set(releaseYears)
        if uniqueReleaseYears.count > 1 {
            return consistentYear
        }

        return nil
    }
}
