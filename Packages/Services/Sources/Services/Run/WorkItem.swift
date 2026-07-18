import Core
import Foundation

public enum WorkTarget: Codable, Equatable, Sendable {
    case track(FixPlanItemIdentity)
    case album(AlbumIdentity)
}

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

public enum WorkState: Codable, Equatable, Sendable {
    case prepared
    case attempting
    case attempted
    case outcome(WorkOutcome)
}

public struct RunWorkItem: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let target: WorkTarget
    public let changeType: ChangeType
    public let oldValue: String?
    public let newValue: String?
    public let confidence: Int
    public let source: String
    public let state: WorkState
    public let detail: String?

    public init(
        id: UUID,
        target: WorkTarget,
        changeType: ChangeType,
        oldValue: String?,
        newValue: String?,
        confidence: Int,
        source: String,
        state: WorkState = .prepared,
        detail: String? = nil
    ) {
        self.id = id
        self.target = target
        self.changeType = changeType
        self.oldValue = oldValue
        self.newValue = newValue
        self.confidence = confidence
        self.source = source
        self.state = state
        self.detail = detail
    }

    public init(item: FixPlanItem) {
        self.init(
            id: item.id,
            target: .track(item.identity),
            changeType: item.changeType,
            oldValue: item.oldValue,
            newValue: item.newValue,
            confidence: item.confidence,
            source: item.source
        )
    }
}
