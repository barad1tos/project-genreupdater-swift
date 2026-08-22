import Core
import Foundation

public enum FixPlanProjectionStatus: String, Equatable, Sendable {
    case empty
    case ready
    case stale
    case unavailable
}

public struct FixPlanProjectionItem: Identifiable, Equatable, Sendable {
    public struct Identity: Equatable, Sendable {
        public let trackID: String
        public let trackName: String
        public let artist: String
        public let album: String

        public init(trackID: String, trackName: String, artist: String, album: String) {
            self.trackID = trackID
            self.trackName = trackName
            self.artist = artist
            self.album = album
        }
    }

    public struct Change: Equatable, Sendable {
        public let type: ChangeType
        public let oldValue: String?
        public let newValue: String?
        public let confidence: Int
        public let source: String

        public init(
            type: ChangeType,
            oldValue: String?,
            newValue: String?,
            confidence: Int,
            source: String
        ) {
            self.type = type
            self.oldValue = oldValue
            self.newValue = newValue
            self.confidence = confidence
            self.source = source
        }
    }

    public let id: UUID
    public let identity: Identity
    public let change: Change
    public let verdict: FixPlanItemVerdict
    public let hasWriteID: Bool

    public init(
        id: UUID,
        identity: Identity,
        change: Change,
        verdict: FixPlanItemVerdict,
        hasWriteID: Bool
    ) {
        self.id = id
        self.identity = identity
        self.change = change
        self.verdict = verdict
        self.hasWriteID = hasWriteID
    }

    public var trackName: String {
        identity.trackName
    }
    public var trackID: String {
        identity.trackID
    }
    public var artist: String {
        identity.artist
    }
    public var album: String {
        identity.album
    }
    public var changeType: ChangeType {
        change.type
    }
    public var oldValue: String? {
        change.oldValue
    }
    public var newValue: String? {
        change.newValue
    }
    public var confidence: Int {
        change.confidence
    }
    public var source: String {
        change.source
    }
}

public struct FixPlanProjection: Equatable, Sendable {
    public struct Lineage: Equatable, Sendable {
        public let planID: FixPlanID?
        public let planRevision: FixPlanRevision?
        public let decisionRevision: ReviewDecisionRevision?
        public let sourceRunID: RunID?

        public init(
            planID: FixPlanID?,
            planRevision: FixPlanRevision?,
            decisionRevision: ReviewDecisionRevision?,
            sourceRunID: RunID?
        ) {
            self.planID = planID
            self.planRevision = planRevision
            self.decisionRevision = decisionRevision
            self.sourceRunID = sourceRunID
        }
    }

    public struct Summary: Equatable, Sendable {
        public let itemCount: Int
        public let acceptedCount: Int
        public let rejectedCount: Int
        public let genreCount: Int
        public let yearCount: Int
        public let trackCleaningCount: Int
        public let albumCleaningCount: Int
        public let artistRenameCount: Int
        public let affectedTrackCount: Int
        public let affectedAlbumCount: Int
        public let averageConfidence: Int?
        public let canApply: Bool

        public init(
            itemCount: Int,
            acceptedCount: Int,
            rejectedCount: Int,
            genreCount: Int,
            yearCount: Int,
            trackCleaningCount: Int,
            albumCleaningCount: Int,
            artistRenameCount: Int,
            affectedTrackCount: Int,
            affectedAlbumCount: Int,
            averageConfidence: Int?,
            canApply: Bool
        ) {
            self.itemCount = itemCount
            self.acceptedCount = acceptedCount
            self.rejectedCount = rejectedCount
            self.genreCount = genreCount
            self.yearCount = yearCount
            self.trackCleaningCount = trackCleaningCount
            self.albumCleaningCount = albumCleaningCount
            self.artistRenameCount = artistRenameCount
            self.affectedTrackCount = affectedTrackCount
            self.affectedAlbumCount = affectedAlbumCount
            self.averageConfidence = averageConfidence
            self.canApply = canApply
        }
    }

    public let revision: ProjectionRevision
    public let status: FixPlanProjectionStatus
    public let lineage: Lineage
    public let scope: ProcessingScopeSnapshot?
    public let summary: Summary
    public let stalenessReasons: [FixPlanStalenessReason]
    public let items: [FixPlanProjectionItem]
    public let operationalIssues: [OperationalIssue]

    public init(
        revision: ProjectionRevision,
        status: FixPlanProjectionStatus,
        lineage: Lineage,
        scope: ProcessingScopeSnapshot?,
        summary: Summary,
        stalenessReasons: [FixPlanStalenessReason],
        items: [FixPlanProjectionItem],
        operationalIssues: [OperationalIssue]
    ) {
        self.revision = revision
        self.status = status
        self.lineage = lineage
        self.scope = scope
        self.summary = summary
        self.stalenessReasons = stalenessReasons
        self.items = items
        self.operationalIssues = operationalIssues
    }

    public var planID: FixPlanID? {
        lineage.planID
    }
    public var planRevision: FixPlanRevision? {
        lineage.planRevision
    }
    public var decisionRevision: ReviewDecisionRevision? {
        lineage.decisionRevision
    }
    public var sourceRunID: RunID? {
        lineage.sourceRunID
    }
    public var itemCount: Int {
        summary.itemCount
    }
    public var acceptedCount: Int {
        summary.acceptedCount
    }
    public var rejectedCount: Int {
        summary.rejectedCount
    }
    public var genreCount: Int {
        summary.genreCount
    }
    public var yearCount: Int {
        summary.yearCount
    }
    public var trackCleaningCount: Int {
        summary.trackCleaningCount
    }
    public var albumCleaningCount: Int {
        summary.albumCleaningCount
    }
    public var artistRenameCount: Int {
        summary.artistRenameCount
    }
    public var affectedTrackCount: Int {
        summary.affectedTrackCount
    }
    public var affectedAlbumCount: Int {
        summary.affectedAlbumCount
    }
    public var averageConfidence: Int? {
        summary.averageConfidence
    }
    public var canApply: Bool {
        summary.canApply
    }

    public func withRevision(_ revision: ProjectionRevision) -> Self {
        Self(
            revision: revision,
            status: status,
            lineage: lineage,
            scope: scope,
            summary: summary,
            stalenessReasons: stalenessReasons,
            items: items,
            operationalIssues: operationalIssues
        )
    }

    public static func empty(revision: ProjectionRevision = .initial) -> Self {
        Self(
            revision: revision,
            status: .empty,
            lineage: Lineage(
                planID: nil,
                planRevision: nil,
                decisionRevision: nil,
                sourceRunID: nil
            ),
            scope: nil,
            summary: Summary(
                itemCount: 0,
                acceptedCount: 0,
                rejectedCount: 0,
                genreCount: 0,
                yearCount: 0,
                trackCleaningCount: 0,
                albumCleaningCount: 0,
                artistRenameCount: 0,
                affectedTrackCount: 0,
                affectedAlbumCount: 0,
                averageConfidence: nil,
                canApply: false
            ),
            stalenessReasons: [],
            items: [],
            operationalIssues: []
        )
    }

    public static func unavailable(message: String, revision: ProjectionRevision = .initial) -> Self {
        Self(
            revision: revision,
            status: .unavailable,
            lineage: Lineage(
                planID: nil,
                planRevision: nil,
                decisionRevision: nil,
                sourceRunID: nil
            ),
            scope: nil,
            summary: Summary(
                itemCount: 0,
                acceptedCount: 0,
                rejectedCount: 0,
                genreCount: 0,
                yearCount: 0,
                trackCleaningCount: 0,
                albumCleaningCount: 0,
                artistRenameCount: 0,
                affectedTrackCount: 0,
                affectedAlbumCount: 0,
                averageConfidence: nil,
                canApply: false
            ),
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
