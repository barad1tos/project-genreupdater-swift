import Core
import Foundation

/// Raw library health tallies, counted once per source of truth: live
/// tracks (full scan including editability) or a cached metrics
/// snapshot. Missing counts stay derived (`total - with`) — the metrics
/// writer records them the same way, so the two sources agree.
public struct ActivityHealthCounts: Equatable, Sendable {
    public let totalTracks: Int
    public let tracksWithGenre: Int
    public let tracksWithYear: Int
    public let tracksWithBoth: Int
    public let protectedFileCount: Int
    public let isProtectedFileCountKnown: Bool

    public init(
        totalTracks: Int,
        tracksWithGenre: Int,
        tracksWithYear: Int,
        tracksWithBoth: Int,
        protectedFileCount: Int,
        isProtectedFileCountKnown: Bool
    ) {
        self.totalTracks = totalTracks
        self.tracksWithGenre = tracksWithGenre
        self.tracksWithYear = tracksWithYear
        self.tracksWithBoth = tracksWithBoth
        self.protectedFileCount = protectedFileCount
        self.isProtectedFileCountKnown = isProtectedFileCountKnown
    }

    public static let empty = Self(
        totalTracks: 0,
        tracksWithGenre: 0,
        tracksWithYear: 0,
        tracksWithBoth: 0,
        protectedFileCount: 0,
        isProtectedFileCountKnown: true
    )

    public static func make(from tracks: [Core.Track]) -> Self {
        var tracksWithGenre = 0
        var tracksWithYear = 0
        var tracksWithBoth = 0
        var protectedFileCount = 0
        var knownEditabilityCount = 0

        for track in tracks {
            let hasGenre = track.hasPresentGenre
            let hasYear = track.year != nil

            if hasGenre {
                tracksWithGenre += 1
            }
            if hasYear {
                tracksWithYear += 1
            }
            if hasGenre, hasYear {
                tracksWithBoth += 1
            }
            if hasKnownEditability(track) {
                knownEditabilityCount += 1
                if !track.canEdit {
                    protectedFileCount += 1
                }
            }
        }

        return Self(
            totalTracks: tracks.count,
            tracksWithGenre: tracksWithGenre,
            tracksWithYear: tracksWithYear,
            tracksWithBoth: tracksWithBoth,
            protectedFileCount: protectedFileCount,
            isProtectedFileCountKnown: tracks.isEmpty || knownEditabilityCount == tracks.count
        )
    }

    public static func make(from metrics: ActivityProjectionMetrics) -> Self {
        Self(
            totalTracks: metrics.totalTracks,
            tracksWithGenre: metrics.tracksWithGenre,
            tracksWithYear: metrics.tracksWithYear,
            tracksWithBoth: metrics.tracksWithBoth,
            protectedFileCount: metrics.protectedFileCount ?? 0,
            isProtectedFileCountKnown: metrics.protectedFileCount != nil
        )
    }

    private static func hasKnownEditability(_ track: Core.Track) -> Bool {
        guard let trackStatus = track.trackStatus?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trackStatus.isEmpty
        else { return false }

        return normalizeTrackStatus(trackStatus) != nil
    }
}

/// Derived library health truth (coverage ratios, weighted score) —
/// computed by one formula on the Services side so no adapter or
/// dashboard re-derives it (D8).
public struct ActivityHealthFacts: Equatable, Sendable {
    public let counts: ActivityHealthCounts
    public let readyUpdateCount: Int
    public let genreCoverageRatio: Double
    public let yearCoverageRatio: Double
    public let consistencyCoverageRatio: Double
    public let editableCoverageRatio: Double
    public let healthScore: Double

    public var healthPercentage: Int {
        Int((healthScore * 100).rounded())
    }

    public var missingGenreCount: Int {
        counts.totalTracks - counts.tracksWithGenre
    }

    public var missingYearCount: Int {
        counts.totalTracks - counts.tracksWithYear
    }

    public init(
        counts: ActivityHealthCounts,
        readyUpdateCount: Int,
        genreCoverageRatio: Double,
        yearCoverageRatio: Double,
        consistencyCoverageRatio: Double,
        editableCoverageRatio: Double,
        healthScore: Double
    ) {
        self.counts = counts
        self.readyUpdateCount = readyUpdateCount
        self.genreCoverageRatio = genreCoverageRatio
        self.yearCoverageRatio = yearCoverageRatio
        self.consistencyCoverageRatio = consistencyCoverageRatio
        self.editableCoverageRatio = editableCoverageRatio
        self.healthScore = healthScore
    }

    public static let empty = make(counts: .empty, readyUpdateCount: 0, failedWriteCount: 0)

    public static func make(
        counts: ActivityHealthCounts,
        readyUpdateCount: Int,
        failedWriteCount: Int
    ) -> Self {
        let genreCoverageRatio = ratio(counts.tracksWithGenre, of: counts.totalTracks)
        let yearCoverageRatio = ratio(counts.tracksWithYear, of: counts.totalTracks)
        let consistencyCoverageRatio = ratio(counts.tracksWithBoth, of: counts.totalTracks)
        let editableCoverageRatio = counts.isProtectedFileCountKnown
            ? ratio(counts.totalTracks - counts.protectedFileCount, of: counts.totalTracks)
            : 0

        return Self(
            counts: counts,
            readyUpdateCount: readyUpdateCount,
            genreCoverageRatio: genreCoverageRatio,
            yearCoverageRatio: yearCoverageRatio,
            consistencyCoverageRatio: consistencyCoverageRatio,
            editableCoverageRatio: editableCoverageRatio,
            healthScore: makeHealthScore(
                counts: counts,
                genreCoverageRatio: genreCoverageRatio,
                yearCoverageRatio: yearCoverageRatio,
                consistencyCoverageRatio: consistencyCoverageRatio,
                failedWriteCount: failedWriteCount
            )
        )
    }

    private static func makeHealthScore(
        counts: ActivityHealthCounts,
        genreCoverageRatio: Double,
        yearCoverageRatio: Double,
        consistencyCoverageRatio: Double,
        failedWriteCount: Int
    ) -> Double {
        guard counts.totalTracks > 0 else { return 0 }

        let coverageScore =
            genreCoverageRatio * HealthPolicy.genreCoverageWeight
                + yearCoverageRatio * HealthPolicy.yearCoverageWeight
                + consistencyCoverageRatio * HealthPolicy.consistencyCoverageWeight
        let protectedPenalty = counts.isProtectedFileCountKnown
            ? ratio(counts.protectedFileCount, of: counts.totalTracks)
            * HealthPolicy.protectedFilePenaltyWeight
            : 0
        let failedWritePenalty = min(
            ratio(failedWriteCount, of: counts.totalTracks) * HealthPolicy.failedWritePenaltyWeight,
            HealthPolicy.failedWritePenaltyCap
        )

        return clamp(coverageScore - protectedPenalty - failedWritePenalty)
    }

    private static func ratio(_ count: Int, of total: Int) -> Double {
        guard total > 0 else { return 0 }
        return clamp(Double(count) / Double(total))
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private enum HealthPolicy {
        static let genreCoverageWeight = 0.35
        static let yearCoverageWeight = 0.35
        static let consistencyCoverageWeight = 0.30
        static let protectedFilePenaltyWeight = 0.25
        static let failedWritePenaltyWeight = 2.0
        static let failedWritePenaltyCap = 0.40
    }
}
