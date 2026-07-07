import Core
import Foundation

public enum FixPlanProjectionStatus: String, Equatable, Sendable {
    case empty
    case ready
    case stale
    case unavailable
}

public struct FixPlanProjectionItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let trackName: String
    public let artist: String
    public let album: String
    public let changeType: ChangeType
    public let oldValue: String?
    public let newValue: String?
    public let confidence: Int
    public let source: String
    public let verdict: FixPlanItemVerdict

    public init(
        id: UUID,
        trackName: String,
        artist: String,
        album: String,
        changeType: ChangeType,
        oldValue: String?,
        newValue: String?,
        confidence: Int,
        source: String,
        verdict: FixPlanItemVerdict
    ) {
        self.id = id
        self.trackName = trackName
        self.artist = artist
        self.album = album
        self.changeType = changeType
        self.oldValue = oldValue
        self.newValue = newValue
        self.confidence = confidence
        self.source = source
        self.verdict = verdict
    }
}

public struct FixPlanProjection: Equatable, Sendable {
    public let revision: ProjectionRevision
    public let status: FixPlanProjectionStatus
    public let planID: FixPlanID?
    public let planRevision: FixPlanRevision?
    public let decisionRevision: ReviewDecisionRevision?
    public let sourceRunID: RunID?
    public let itemCount: Int
    public let acceptedCount: Int
    public let rejectedCount: Int
    public let genreCount: Int
    public let yearCount: Int
    public let averageConfidence: Int?
    public let canApply: Bool
    public let stalenessReasons: [FixPlanStalenessReason]
    public let items: [FixPlanProjectionItem]
    public let operationalIssues: [OperationalIssue]

    public init(
        revision: ProjectionRevision,
        status: FixPlanProjectionStatus,
        planID: FixPlanID?,
        planRevision: FixPlanRevision?,
        decisionRevision: ReviewDecisionRevision?,
        sourceRunID: RunID?,
        itemCount: Int,
        acceptedCount: Int,
        rejectedCount: Int,
        genreCount: Int,
        yearCount: Int,
        averageConfidence: Int?,
        canApply: Bool,
        stalenessReasons: [FixPlanStalenessReason],
        items: [FixPlanProjectionItem],
        operationalIssues: [OperationalIssue]
    ) {
        self.revision = revision
        self.status = status
        self.planID = planID
        self.planRevision = planRevision
        self.decisionRevision = decisionRevision
        self.sourceRunID = sourceRunID
        self.itemCount = itemCount
        self.acceptedCount = acceptedCount
        self.rejectedCount = rejectedCount
        self.genreCount = genreCount
        self.yearCount = yearCount
        self.averageConfidence = averageConfidence
        self.canApply = canApply
        self.stalenessReasons = stalenessReasons
        self.items = items
        self.operationalIssues = operationalIssues
    }

    public func withRevision(_ revision: ProjectionRevision) -> Self {
        Self(
            revision: revision,
            status: status,
            planID: planID,
            planRevision: planRevision,
            decisionRevision: decisionRevision,
            sourceRunID: sourceRunID,
            itemCount: itemCount,
            acceptedCount: acceptedCount,
            rejectedCount: rejectedCount,
            genreCount: genreCount,
            yearCount: yearCount,
            averageConfidence: averageConfidence,
            canApply: canApply,
            stalenessReasons: stalenessReasons,
            items: items,
            operationalIssues: operationalIssues
        )
    }

    public static func empty(revision: ProjectionRevision = .initial) -> Self {
        Self(
            revision: revision,
            status: .empty,
            planID: nil,
            planRevision: nil,
            decisionRevision: nil,
            sourceRunID: nil,
            itemCount: 0,
            acceptedCount: 0,
            rejectedCount: 0,
            genreCount: 0,
            yearCount: 0,
            averageConfidence: nil,
            canApply: false,
            stalenessReasons: [],
            items: [],
            operationalIssues: []
        )
    }

    public static func unavailable(message: String, revision: ProjectionRevision = .initial) -> Self {
        Self(
            revision: revision,
            status: .unavailable,
            planID: nil,
            planRevision: nil,
            decisionRevision: nil,
            sourceRunID: nil,
            itemCount: 0,
            acceptedCount: 0,
            rejectedCount: 0,
            genreCount: 0,
            yearCount: 0,
            averageConfidence: nil,
            canApply: false,
            stalenessReasons: [],
            items: [],
            operationalIssues: [
                OperationalIssue(
                    id: "fix-plan-unavailable",
                    category: .temporaryUnavailable,
                    summary: "Fix plan unavailable",
                    technicalDetail: message
                )
            ]
        )
    }
}
