import Core
import Services

struct UpdateRunChangeBreakdown: Equatable {
    let changeType: ChangeType
    let changeCount: Int
    let trackCount: Int
    let albumCount: Int

    var summary: String {
        [
            "\(changeCount.formatted()) \(Self.noun("change", count: changeCount))",
            "\(trackCount.formatted()) \(Self.noun("track", count: trackCount))",
            "\(albumCount.formatted()) \(Self.noun("album", count: albumCount))",
        ].joined(separator: ", ")
    }

    private static func noun(_ singular: String, count: Int) -> String {
        count == 1 ? singular : "\(singular)s"
    }
}

enum UpdateRunOutcome: Equatable {
    case noChange
    case skipped
    case failed

    var displayLabel: String {
        switch self {
        case .noChange:
            "No-op"
        case .skipped:
            "Skipped"
        case .failed:
            "Failed"
        }
    }

    var sortIndex: Int {
        switch self {
        case .noChange:
            0
        case .skipped:
            1
        case .failed:
            2
        }
    }

    func itemNoun(count: Int) -> String {
        switch self {
        case .noChange:
            count == 1 ? "no-op" : "no-ops"
        case .skipped:
            count == 1 ? "skipped track" : "skipped tracks"
        case .failed:
            count == 1 ? "failure" : "failures"
        }
    }
}

struct UpdateRunOutcomeBreakdown: Identifiable, Equatable {
    let outcome: UpdateRunOutcome
    let operation: String
    let reason: String?
    let count: Int
    let trackCount: Int
    let albumCount: Int

    var id: String {
        [outcome.displayLabel, operation, reason ?? ""].joined(separator: "\u{1F}")
    }

    var title: String {
        "\(outcome.displayLabel) \(operation)"
    }

    var summary: String {
        var parts = [
            "\(count.formatted()) \(outcome.itemNoun(count: count))",
            "\(trackCount.formatted()) \(Self.noun("track", count: trackCount))",
        ]
        if albumCount > 0 {
            parts.append("\(albumCount.formatted()) \(Self.noun("album", count: albumCount))")
        }
        if let reason {
            parts.append(reason)
        }
        return parts.joined(separator: ", ")
    }

    private static func noun(_ singular: String, count: Int) -> String {
        count == 1 ? singular : "\(singular)s"
    }
}

extension UpdateRunReport {
    static func makeOutcomeBreakdown(
        noOpEntries: [ChangeLogEntry],
        failures: [UpdateRunFailure],
        trackStatuses: [String: TrackProcessingStatus],
        trackLookup: [String: Track]
    ) -> [UpdateRunOutcomeBreakdown] {
        let rows = makeNoOpOutcomeBreakdown(from: noOpEntries, trackLookup: trackLookup)
            + makeSkippedOutcomeBreakdown(trackStatuses: trackStatuses, trackLookup: trackLookup)
            + makeFailureOutcomeBreakdown(from: failures)
        return rows.sorted(by: outcomeBreakdownSort)
    }

    func appendOutcomeBreakdown(to lines: inout [String]) {
        guard !outcomeBreakdown.isEmpty else { return }

        lines.append("Outcome Breakdown")
        for item in outcomeBreakdown {
            lines.append("- \(item.title): \(item.summary)")
        }
        lines.append("")
    }

    private static func makeNoOpOutcomeBreakdown(
        from entries: [ChangeLogEntry],
        trackLookup: [String: Track]
    ) -> [UpdateRunOutcomeBreakdown] {
        Dictionary(grouping: entries, by: \.changeType)
            .map { changeType, entries in
                UpdateRunOutcomeBreakdown(
                    outcome: .noChange,
                    operation: changeType.displayLabel,
                    reason: nil,
                    count: entries.count,
                    trackCount: Set(entries.map(\.trackID)).count,
                    albumCount: Set(entries.map { albumIdentity(for: $0, trackLookup: trackLookup) }).count
                )
            }
    }

    private static func makeSkippedOutcomeBreakdown(
        trackStatuses: [String: TrackProcessingStatus],
        trackLookup: [String: Track]
    ) -> [UpdateRunOutcomeBreakdown] {
        let skippedTrackIDs = trackStatuses.compactMap { trackID, status -> String? in
            if case .skipped = status {
                return trackID
            }
            return nil
        }
        guard !skippedTrackIDs.isEmpty else { return [] }

        let albumCount = Set(skippedTrackIDs.compactMap { trackID in
            trackLookup[trackID].map { albumIdentity(for: $0) }
        }).count
        return [
            UpdateRunOutcomeBreakdown(
                outcome: .skipped,
                operation: "Processing",
                reason: "Skipped before write",
                count: skippedTrackIDs.count,
                trackCount: skippedTrackIDs.count,
                albumCount: albumCount
            ),
        ]
    }

    private static func makeFailureOutcomeBreakdown(
        from failures: [UpdateRunFailure]
    ) -> [UpdateRunOutcomeBreakdown] {
        Dictionary(grouping: failures, by: \.message)
            .map { message, failures in
                UpdateRunOutcomeBreakdown(
                    outcome: .failed,
                    operation: "Processing",
                    reason: message,
                    count: failures.count,
                    trackCount: Set(failures.map(\.technicalID)).count,
                    albumCount: Set(failures.filter(\.hasKnownTrack).map {
                        UpdateRunAlbumIdentity(artist: $0.artist, album: $0.album)
                    }).count
                )
            }
    }

    private static func outcomeBreakdownSort(
        _ left: UpdateRunOutcomeBreakdown,
        _ right: UpdateRunOutcomeBreakdown
    ) -> Bool {
        if left.outcome.sortIndex != right.outcome.sortIndex {
            return left.outcome.sortIndex < right.outcome.sortIndex
        }
        let operationOrder = left.operation.localizedStandardCompare(right.operation)
        if operationOrder != .orderedSame {
            return operationOrder == .orderedAscending
        }
        return (left.reason ?? "").localizedStandardCompare(right.reason ?? "") == .orderedAscending
    }
}
