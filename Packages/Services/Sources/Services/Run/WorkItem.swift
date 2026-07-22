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

    func canFollow(_ previous: Self) -> Bool {
        switch (previous, self) {
        case (.prepared, _),
             (.attempting, .attempting),
             (.attempting, .attempted),
             (.attempting, .outcome),
             (.attempted, .attempted),
             (.attempted, .outcome):
            true
        case let (.outcome(previous), .outcome(next)):
            previous == next
        case (.attempting, .prepared),
             (.attempted, .prepared),
             (.attempted, .attempting),
             (.outcome, .prepared),
             (.outcome, .attempting),
             (.outcome, .attempted):
            false
        }
    }
}

enum WorkStateError: Error, Equatable {
    case invalid(current: WorkState, next: WorkState)
}

public enum CheckpointBoundary: Equatable, Sendable {
    case beforeAttempt
    case afterAttempt
    case afterVerification
}

/// An atomic durable state update for one or more run work items.
public struct WorkCheckpoint: Equatable, Sendable {
    public let boundary: CheckpointBoundary
    let states: [UUID: WorkState]

    private init(boundary: CheckpointBoundary, states: [UUID: WorkState]) {
        self.boundary = boundary
        self.states = states
    }

    public static func beforeAttempt(_ itemIDs: [UUID]) -> Self {
        Self(
            boundary: .beforeAttempt,
            states: Dictionary(uniqueKeysWithValues: Set(itemIDs).map { ($0, .attempting) })
        )
    }

    public static func afterAttempt(_ itemIDs: [UUID]) -> Self {
        Self(
            boundary: .afterAttempt,
            states: Dictionary(uniqueKeysWithValues: Set(itemIDs).map { ($0, .attempted) })
        )
    }

    public static func afterVerification(_ outcomes: [UUID: WorkOutcome]) -> Self {
        Self(
            boundary: .afterVerification,
            states: outcomes.mapValues(WorkState.outcome)
        )
    }
}

public typealias WorkCheckpointSink = @Sendable (WorkCheckpoint) async throws -> Void

enum WorkCheckpointError: Error, Equatable {
    case invalid(CheckpointBoundary, writeAdjacent: Bool, reason: String)
    case persistence(CheckpointBoundary, writeAdjacent: Bool)
    case store(CheckpointStoreFailure)

    var needsRecovery: Bool {
        switch self {
        case let .invalid(_, writeAdjacent, _), let .persistence(_, writeAdjacent):
            writeAdjacent
        case let .store(failure):
            failure.isWriteAdjacent
        }
    }
}

extension WorkCheckpointError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .invalid(boundary, _, reason):
            "Invalid \(String(describing: boundary)) work checkpoint: \(reason)"
        case let .persistence(boundary, _):
            "Could not persist \(String(describing: boundary)) work checkpoint"
        case let .store(failure):
            failure.errorDescription
        }
    }
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

    func transition(to nextState: WorkState) throws -> Self {
        try transition(to: nextState, detail: detail)
    }

    func transition(to nextState: WorkState, detail: String?) throws -> Self {
        guard Self.canTransition(from: state, to: nextState) else {
            throw WorkStateError.invalid(current: state, next: nextState)
        }
        return Self(
            id: id,
            target: target,
            change: change,
            state: nextState,
            detail: detail
        )
    }

    private static func canTransition(from state: WorkState, to nextState: WorkState) -> Bool {
        switch (state, nextState) {
        case (.prepared, .attempting),
             (.attempting, .attempted),
             (.attempted, .outcome):
            true
        case let (.prepared, .outcome(outcome)):
            outcome != .written
        // An `.attempting` item provably never reached Music.app (`onAttempt` promotes to
        // `.attempted` on every dispatched path), so any conclusive outcome except `.written`
        // is a truthful terminal — e.g. a batch dispatch-deadline fallback re-verifying the
        // item as a no-op. `.written` still requires a confirmed `.attempted` dispatch.
        case let (.attempting, .outcome(outcome)):
            outcome != .written
        case (.prepared, .prepared),
             (.attempting, .attempting),
             (.attempted, .attempted),
             (.outcome, .outcome):
            state == nextState
        case (.prepared, .attempted),
             (.attempting, .prepared),
             (.attempted, .prepared),
             (.attempted, .attempting),
             (.outcome, .prepared),
             (.outcome, .attempting),
             (.outcome, .attempted):
            false
        }
    }
}
