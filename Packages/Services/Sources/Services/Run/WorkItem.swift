import Core
import Foundation

/// The library identity a run plans to inspect or change.
public enum WorkTarget: Codable, Equatable, Sendable {
    case track(FixPlanItemIdentity)
    case album(AlbumIdentity)
}

/// The explicit result of work attempted by the pipeline.
public enum WorkOutcome: String, CaseIterable, Codable, Equatable, Sendable {
    case noFixNeeded
    case fixProposed
    case written
    case needsReview
    case skipped
    case failed
    case deferred
    case dismissed
}

/// Durable progress kept separately from the result of the work.
public enum WorkState: Codable, Equatable, Sendable {
    case prepared
    case attempting
    /// The attempt finished, but verification or its terminal outcome is not yet recorded.
    case attempted
    case outcome(WorkOutcome)
}

/// Metadata change proposed for one work target.
public struct WorkChange: Codable, Equatable, Sendable {
    public let changeType: ChangeType
    public let oldValue: String?
    public let newValue: String?
    public let confidence: Int
    public let source: String

    public init(
        changeType: ChangeType,
        oldValue: String?,
        newValue: String?,
        confidence: Int,
        source: String
    ) {
        self.changeType = changeType
        self.oldValue = oldValue
        self.newValue = newValue
        self.confidence = confidence
        self.source = source
    }
}

/// One immutable unit of run planning and processing.
public struct RunWorkItem: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let target: WorkTarget
    public let change: WorkChange
    public let state: WorkState
    public let detail: String?

    public init(
        id: UUID,
        target: WorkTarget,
        change: WorkChange,
        state: WorkState = .prepared,
        detail: String? = nil
    ) {
        self.id = id
        self.target = target
        self.change = change
        self.state = state
        self.detail = detail
    }

    public init(item: FixPlanItem) {
        self.init(
            id: item.id,
            target: .track(item.identity),
            change: WorkChange(
                changeType: item.changeType,
                oldValue: item.oldValue,
                newValue: item.newValue,
                confidence: item.confidence,
                source: item.source
            )
        )
    }
}
