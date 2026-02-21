import Core
import Foundation

// MARK: - Dry Run Report

/// Summarizes proposed changes from a dry-run analysis without applying them.
///
/// Built by `UpdateViewModel` after a dry-run completes, surfacing counts
/// by change type and affected tracks for the summary sheet.
public struct DryRunReport: Sendable {
    /// All proposed changes that passed the confidence threshold.
    public let proposedChanges: [ProposedChange]

    /// Total number of proposed changes.
    public var totalChanges: Int {
        proposedChanges.count
    }

    /// Number of genre-related changes (genre updates).
    public var genreChanges: Int {
        proposedChanges.count { $0.changeType == .genreUpdate }
    }

    /// Number of year-related changes (year updates and reverts).
    public var yearChanges: Int {
        proposedChanges.count {
            $0.changeType == .yearUpdate || $0.changeType == .yearRevert
        }
    }

    /// Number of track cleaning changes.
    public var trackCleaningChanges: Int {
        proposedChanges.count { $0.changeType == .trackCleaning }
    }

    /// Number of album cleaning changes.
    public var albumCleaningChanges: Int {
        proposedChanges.count { $0.changeType == .albumCleaning }
    }

    /// Number of artist rename changes.
    public var artistRenameChanges: Int {
        proposedChanges.count { $0.changeType == .artistRename }
    }

    /// Number of distinct tracks affected by at least one change.
    public var affectedTrackCount: Int {
        Set(proposedChanges.map(\.track.id)).count
    }

    /// Average confidence across all proposed changes (0-100).
    public var averageConfidence: Int {
        guard !proposedChanges.isEmpty else { return 0 }
        let sum = proposedChanges.reduce(0) { $0 + $1.confidence }
        return sum / proposedChanges.count
    }

    /// Changes grouped by type for display in the summary.
    public var changesByType: [(type: ChangeType, count: Int)] {
        ChangeType.allCases
            .map { type in
                (type: type, count: proposedChanges.count {
                    $0.changeType == type
                })
            }
            .filter { $0.count >= 1 }
    }

    public init(proposedChanges: [ProposedChange]) {
        self.proposedChanges = proposedChanges
    }
}
