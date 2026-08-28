import Core
import Foundation

public enum FixPlanProjector {
    public static func makeProjection(
        plan: FixPlan,
        decision: FixPlanReviewDecision,
        staleness: FixPlanStaleness
    ) -> FixPlanProjection {
        let verdicts = Dictionary(
            uniqueKeysWithValues: decision.itemDecisions.map { ($0.itemID, $0.verdict) }
        )
        let items = plan.items.map { item in
            let values = ChangeDisplay.values(
                oldValue: item.oldValue,
                newValue: item.newValue,
                albumArtistChange: item.albumArtistChange
            )
            return FixPlanProjectionItem(
                id: item.id,
                identity: FixPlanProjectionItem.Identity(
                    trackID: item.identity.readID,
                    trackName: item.identity.trackName,
                    artist: item.identity.artist,
                    album: item.identity.album
                ),
                change: FixPlanProjectionItem.Change(
                    type: item.changeType,
                    oldValue: values.oldValue,
                    newValue: values.newValue,
                    confidence: item.confidence,
                    source: item.source
                ),
                verdict: verdicts[item.id] ?? .rejected,
                hasWriteID: hasWriteID(item.identity.appleScriptID)
            )
        }
        let acceptedCount = items.count(where: { $0.verdict == .accepted })
        let missingIdentityCount = items.count { $0.verdict == .accepted && !$0.hasWriteID }
        let hasCertifiedAdmission = hasCertifiedAdmission(for: plan)
        let status: FixPlanProjectionStatus = staleness.isStale ? .stale : .ready

        return FixPlanProjection(
            revision: .initial,
            status: status,
            lineage: FixPlanProjection.Lineage(
                planID: plan.id,
                planRevision: plan.revision,
                decisionRevision: decision.revision,
                sourceRunID: plan.sourceRunID
            ),
            scope: plan.scope,
            summary: makeSummary(
                items: items,
                status: status,
                acceptedCount: acceptedCount,
                missingIdentityCount: missingIdentityCount,
                hasCertifiedAdmission: hasCertifiedAdmission
            ),
            stalenessReasons: staleness.reasons,
            items: items,
            operationalIssues: makeOperationalIssues(
                hasCertifiedAdmission: hasCertifiedAdmission,
                missingIdentityCount: missingIdentityCount
            )
        )
    }

    private static func hasCertifiedAdmission(for plan: FixPlan) -> Bool {
        guard case let .certified(admission) = plan.admission else { return false }
        return admission.certifies(scope: plan.scope)
    }

    private static func makeOperationalIssues(
        hasCertifiedAdmission: Bool,
        missingIdentityCount: Int
    ) -> [OperationalIssue] {
        var issues: [OperationalIssue] = []
        if !hasCertifiedAdmission {
            issues.append(OperationalIssue(
                id: "fix-plan-admission",
                category: .safetyBlocked,
                summary: "Certified library evidence required",
                technicalDetail: "This fix plan has no valid library evidence for its captured processing scope."
            ))
        }
        if missingIdentityCount > 0 {
            issues.append(OperationalIssue(
                id: "fix-plan-write-identity",
                category: .safetyBlocked,
                summary: "Write identity required",
                technicalDetail: "Accepted items without AppleScript ID: \(missingIdentityCount)"
            ))
        }
        return issues
    }

    private static func makeSummary(
        items: [FixPlanProjectionItem],
        status: FixPlanProjectionStatus,
        acceptedCount: Int,
        missingIdentityCount: Int,
        hasCertifiedAdmission: Bool
    ) -> FixPlanProjection.Summary {
        let affectedAlbums = Set(items.map {
            AlbumIdentity.key(artist: $0.artist, album: $0.album)
        })
        let affectedTracks = Set(items.map(\.trackID))

        return FixPlanProjection.Summary(
            itemCount: items.count,
            acceptedCount: acceptedCount,
            rejectedCount: items.count - acceptedCount,
            genreCount: items.count(where: { $0.changeType == .genreUpdate }),
            yearCount: items.count(where: { $0.changeType == .yearUpdate || $0.changeType == .yearRevert }),
            trackCleaningCount: items.count(where: { $0.changeType == .trackCleaning }),
            albumCleaningCount: items.count(where: { $0.changeType == .albumCleaning }),
            artistRenameCount: items.count(where: { $0.changeType == .artistRename }),
            affectedTrackCount: affectedTracks.count,
            affectedAlbumCount: affectedAlbums.count,
            averageConfidence: averageConfidence(for: items),
            canApply: status == .ready
                && acceptedCount > 0
                && missingIdentityCount == 0
                && hasCertifiedAdmission
        )
    }

    /// Scores are unclamped domain values (Python parity: a perfect match is
    /// 125), and every consumer of this renders it as "N% avg confidence".
    /// Clamping belongs here, at the point the score becomes a percentage.
    private static func averageConfidence(for items: [FixPlanProjectionItem]) -> Int? {
        guard !items.isEmpty else { return nil }
        let total = items.reduce(0) { $0 + $1.confidence }
        let average = Int((Double(total) / Double(items.count)).rounded())
        return min(100, max(0, average))
    }

    /// The single write-ID rule: a non-blank AppleScript ID. Browse
    /// writable counts consume the same predicate so the two surfaces
    /// can never disagree on a safety fact.
    static func hasWriteID(_ id: String?) -> Bool {
        id?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}
