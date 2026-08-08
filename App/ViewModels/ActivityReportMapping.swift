import Core
import DesignUI
import Foundation
import Services

/// Format-only maps from the projection's report facts to DesignUI
/// rows (P8): every derivation — bounds, fallbacks, labels, buckets —
/// happens in ActivityReportFacts on the builder side.
extension ActivitySnapshotAdapter {
    static func makeChangeLog(from facts: ActivityReportFacts) -> [LogEntry] {
        facts.changeLog.map { item in
            LogEntry(
                id: item.id,
                time: item.timeLabel,
                type: makeDesignChangeType(from: item.changeType),
                track: item.trackTitle,
                artist: item.artist,
                old: item.oldValue,
                new: item.newValue,
                conf: nil
            )
        }
    }

    static func makeReportStats(from facts: ActivityReportFacts) -> ReportStats {
        ReportStats(
            processed: facts.stats.processed,
            genres: facts.stats.genreUpdates,
            years: facts.stats.yearUpdates
        )
    }

    static func makeChartData(from buckets: [ActivityReportBucket]) -> [ChartDatum] {
        buckets.map { bucket in
            ChartDatum(id: bucket.id, label: bucket.label, count: bucket.count)
        }
    }

    private static func makeDesignChangeType(from changeType: Core.ChangeType) -> DesignUI.ChangeType {
        switch changeType {
        case .genreUpdate:
            .genre
        case .yearUpdate:
            .year
        case .trackCleaning:
            .track
        case .albumCleaning:
            .album
        case .artistRename:
            .artist
        case .yearRevert:
            .revert
        }
    }
}
