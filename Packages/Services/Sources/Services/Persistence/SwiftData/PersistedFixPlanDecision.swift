import Foundation
import SwiftData

@Model
public final class PersistedFixPlanDecision {
    /// One current decision per plan; superseding revisions update this row in
    /// place through the store's compare-and-swap write.
    @Attribute(.unique) public var planID: UUID
    public var planRevision: Int
    public var decisionRevision: Int
    public var decidedAt: Date
    public var itemDecisionsData: Data

    public init(
        planID: UUID,
        planRevision: Int,
        decisionRevision: Int,
        decidedAt: Date,
        itemDecisionsData: Data
    ) {
        self.planID = planID
        self.planRevision = planRevision
        self.decisionRevision = decisionRevision
        self.decidedAt = decidedAt
        self.itemDecisionsData = itemDecisionsData
    }
}
