import Core
import DesignUI
import Foundation
import Services

enum UpgradeCopy {
    static let cleaningWrite = """
    Applying accepted track cleaning, album cleaning, or artist renames requires Week Pass or Pro. \
    Preview and review remain available.
    """
}

enum FixPlanAdapter {
    static func makeSnapshot(
        from projection: FixPlanProjection,
        hasCleaningAccess: Bool
    ) -> DesignUI.FixPlanSnapshot {
        DesignUI.FixPlanSnapshot(
            status: makeStatus(projection.status),
            planID: projection.planID?.description,
            planRevision: projection.planRevision?.value,
            decisionRevision: projection.decisionRevision?.value,
            projectionRevision: projection.revision.value,
            itemCount: projection.itemCount,
            acceptedCount: projection.acceptedCount,
            rejectedCount: projection.rejectedCount,
            genreCount: projection.genreCount,
            yearCount: projection.yearCount,
            averageConfidence: projection.averageConfidence,
            canApply: projection.canApply,
            writeAccess: writeAccess(
                for: projection,
                hasCleaningAccess: hasCleaningAccess
            ),
            issues: projection.operationalIssues.map(issueText),
            items: projection.items.map(makeItem)
        )
    }

    private static func writeAccess(
        for projection: FixPlanProjection,
        hasCleaningAccess: Bool
    ) -> DesignUI.ContentAccess {
        let requiresCleaningAccess = projection.items.contains { item in
            item.verdict == .accepted && item.changeType.requiredWriteFeature == .artistAlbumCleaning
        }
        guard requiresCleaningAccess, !hasCleaningAccess else { return .available }
        return .locked(message: UpgradeCopy.cleaningWrite)
    }

    private static func makeStatus(_ status: FixPlanProjectionStatus) -> DesignUI.FixPlanStatus {
        switch status {
        case .empty:
            .empty
        case .ready:
            .ready
        case .stale:
            .stale
        case .unavailable:
            .unavailable
        }
    }

    private static func makeItem(_ item: FixPlanProjectionItem) -> DesignUI.FixPlanItem {
        DesignUI.FixPlanItem(
            id: item.id.uuidString,
            track: item.trackName,
            artist: item.artist,
            album: item.album,
            type: makeType(item.changeType),
            old: item.oldValue,
            new: item.newValue ?? "none",
            confidence: clampedConfidence(item.confidence),
            source: item.source,
            verdict: makeVerdict(item.verdict),
            hasWriteID: item.hasWriteID
        )
    }

    private static func makeType(_ type: Core.ChangeType) -> DesignUI.ChangeType {
        switch type {
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

    private static func makeVerdict(_ verdict: FixPlanItemVerdict) -> DesignUI.FixPlanVerdict {
        switch verdict {
        case .accepted:
            .accepted
        case .rejected:
            .rejected
        }
    }

    private static func issueText(_ issue: OperationalIssue) -> String {
        guard let detail = issue.technicalDetail else { return issue.summary }
        return "\(issue.summary): \(detail)"
    }

    private static func clampedConfidence(_ confidence: Int) -> Double {
        Double(min(max(confidence, 0), 100)) / 100
    }
}
