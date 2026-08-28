import Foundation

/// Freezes a preview run's proposed changes into an immutable fix plan
/// (ADR 0017).
public enum FixPlanCapture {
    public struct Evidence: Sendable {
        public let scope: ProcessingScopeSnapshot
        public let admission: ProcessingAdmission

        public init(scope: ProcessingScopeSnapshot, admission: ProcessingAdmission) throws {
            guard admission.certifies(scope: scope) else {
                throw ProcessingAdmissionRejection.scopeMismatch
            }
            self.scope = scope
            self.admission = admission
        }
    }

    /// Pure mapping — no determination logic. Returns `nil` for empty
    /// proposals: a no-fix analysis is a sync/no-op record, not a fix plan.
    public static func makePlan(
        from proposals: [ProposedChange],
        sourceRunID: RunID,
        evidence: Evidence,
        configuration: FixPlanConfig,
        createdAt: Date
    ) throws -> FixPlan? {
        guard !proposals.isEmpty else { return nil }

        let items = proposals.map { proposal in
            FixPlanItem(
                id: proposal.id,
                identity: FixPlanItemIdentity(
                    readID: proposal.track.id,
                    appleScriptID: proposal.track.appleScriptID,
                    artist: proposal.track.artist,
                    album: proposal.track.album,
                    trackName: proposal.track.name,
                    albumArtist: proposal.track.albumArtist
                ),
                changeType: proposal.changeType,
                oldValue: proposal.oldValue,
                newValue: proposal.newValue,
                confidence: proposal.confidence,
                source: proposal.source,
                albumArtistChange: proposal.albumArtistChange
            )
        }

        return try FixPlan(
            id: FixPlanID(),
            revision: .initial,
            sourceRunID: sourceRunID,
            createdAt: createdAt,
            configuration: configuration,
            scope: evidence.scope,
            admission: evidence.admission,
            items: items
        )
    }
}
