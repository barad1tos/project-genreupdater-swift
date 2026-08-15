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
    /// The write may have reached Music.app, but its physical and verified outcome is still unknown.
    case attempted
    case outcome(WorkOutcome)

    /// Multi-step reachability under the transition closure, used to reconcile
    /// durable child rows against a stale parent payload. Unlike the
    /// single-step legality in `RunWorkItem.canTransition`, `(.prepared, _)`
    /// is true because a row may legally advance through any number of
    /// checkpoints while the payload still holds its preflight state.
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

/// A grouped request to transition run work-item states at a checkpoint boundary.
/// Durability is established only after its sink succeeds.
public struct WorkCheckpoint: Equatable, Sendable {
    public let boundary: CheckpointBoundary
    let states: [UUID: WorkState]
    let writeChanges: [UUID: WorkChange]

    private init(
        boundary: CheckpointBoundary,
        states: [UUID: WorkState],
        writeChanges: [UUID: WorkChange] = [:]
    ) {
        self.boundary = boundary
        self.states = states
        self.writeChanges = writeChanges
    }

    static func beforeAttempt(_ itemIDs: [UUID]) -> Self {
        Self(
            boundary: .beforeAttempt,
            states: Dictionary(uniqueKeysWithValues: Set(itemIDs).map { ($0, .attempting) })
        )
    }

    /// Carries the authoritative metadata effect into the durable pre-dispatch checkpoint.
    public static func beforeAttempt(_ writeChanges: [UUID: WorkChange]) -> Self {
        Self(
            boundary: .beforeAttempt,
            states: writeChanges.mapValues { _ in .attempting },
            writeChanges: writeChanges
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

/// Public across the package boundary: dismissal and checkpoint APIs throw
/// it, and the App command layer maps it to typed rejections.
public enum WorkCheckpointError: Error, Equatable {
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
    public var errorDescription: String? {
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
    public let albumArtistChange: AlbumArtistChange?

    public init(
        changeType: ChangeType,
        oldValue: String?,
        newValue: String?,
        confidence: Int,
        source: String,
        albumArtistChange: AlbumArtistChange? = nil
    ) {
        self.changeType = changeType
        self.oldValue = oldValue
        self.newValue = newValue
        self.confidence = confidence
        self.source = source
        self.albumArtistChange = albumArtistChange
    }

    func isValidReconciliation(of planned: Self) -> Bool {
        let hasMatchingPrimaryEffect = changeType == planned.changeType
            && oldValue == planned.oldValue
            && newValue == planned.newValue
            && confidence == planned.confidence
            && source == planned.source
        let hasValidAlbumArtistTarget = albumArtistChange?.newValue == nil
            || albumArtistChange?.newValue == newValue
        return hasMatchingPrimaryEffect && hasValidAlbumArtistTarget
    }
}

/// One immutable unit of run planning and processing.
public struct RunWorkItem: Codable, Equatable, Sendable, Identifiable {
    private enum CodingKeys: String, CodingKey {
        case id
        case target
        case change
        case writeChange
        case state
        case detail
        case dismissedAt
    }

    public let id: UUID
    public let target: WorkTarget
    public let change: WorkChange
    /// Authoritative metadata effect persisted immediately before dispatch.
    /// Nil means the item has not crossed that boundary, or predates this evidence.
    public let writeChange: WorkChange?
    public let state: WorkState
    public let detail: String?
    /// When the user explicitly dismissed this item (ADR 0006); nil for
    /// every other closure. Optional so legacy payloads decode unchanged.
    public let dismissedAt: Date?

    public init(
        id: UUID,
        target: WorkTarget,
        change: WorkChange,
        state: WorkState = .prepared,
        detail: String? = nil,
        dismissedAt: Date? = nil
    ) {
        self.init(
            id: id,
            target: target,
            change: change,
            state: state,
            detail: detail,
            dismissedAt: dismissedAt,
            writeChange: nil
        )
    }

    init(
        id: UUID,
        target: WorkTarget,
        change: WorkChange,
        state: WorkState,
        detail: String? = nil,
        dismissedAt: Date? = nil,
        writeChange: WorkChange?
    ) {
        precondition(Self.hasValidWriteChange(writeChange, planned: change, state: state))
        self.id = id
        self.target = target
        self.change = change
        self.writeChange = writeChange
        self.state = state
        self.detail = detail
        self.dismissedAt = dismissedAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(UUID.self, forKey: .id)
        let target = try values.decode(WorkTarget.self, forKey: .target)
        let change = try values.decode(WorkChange.self, forKey: .change)
        let writeChange = try values.decodeIfPresent(WorkChange.self, forKey: .writeChange)
        let state = try values.decode(WorkState.self, forKey: .state)
        guard Self.hasValidWriteChange(writeChange, planned: change, state: state) else {
            throw DecodingError.dataCorruptedError(
                forKey: .writeChange,
                in: values,
                debugDescription: "Write effect contradicts the planned change or work state"
            )
        }
        self.id = id
        self.target = target
        self.change = change
        self.writeChange = writeChange
        self.state = state
        detail = try values.decodeIfPresent(String.self, forKey: .detail)
        dismissedAt = try values.decodeIfPresent(Date.self, forKey: .dismissedAt)
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
                source: item.source,
                albumArtistChange: item.albumArtistChange
            )
        )
    }

    func transition(to nextState: WorkState) throws -> Self {
        try transition(to: nextState, detail: detail, writeChange: nil)
    }

    /// Replaces the audit note without a state transition. Terminal outcome
    /// immutability is untouched — only the human-facing detail changes.
    func annotated(detail: String?) -> Self {
        Self(
            id: id,
            target: target,
            change: change,
            state: state,
            detail: detail,
            dismissedAt: dismissedAt,
            writeChange: writeChange
        )
    }

    /// Stamps the user-dismissal timestamp and replaces the detail; callers
    /// must only invoke it after a transition into `.dismissed`.
    func recordingDismissal(detail: String?, at timestamp: Date) -> Self {
        Self(
            id: id,
            target: target,
            change: change,
            state: state,
            detail: detail,
            dismissedAt: timestamp,
            writeChange: writeChange
        )
    }

    func transition(
        to nextState: WorkState,
        detail: String?,
        writeChange suppliedWriteChange: WorkChange? = nil
    ) throws -> Self {
        guard Self.canTransition(from: state, to: nextState) else {
            throw WorkStateError.invalid(current: state, next: nextState)
        }
        if let suppliedWriteChange {
            guard suppliedWriteChange.isValidReconciliation(of: change),
                  writeChange != nil || nextState == .attempting
            else {
                throw WorkStateError.invalid(current: state, next: nextState)
            }
        }
        if let writeChange, let suppliedWriteChange, writeChange != suppliedWriteChange {
            throw WorkStateError.invalid(current: state, next: nextState)
        }
        return Self(
            id: id,
            target: target,
            change: change,
            state: nextState,
            detail: detail,
            dismissedAt: dismissedAt,
            writeChange: writeChange ?? suppliedWriteChange
        )
    }

    var effectiveChange: WorkChange {
        writeChange ?? change
    }

    func canReconcileWriteChange(from previous: Self) -> Bool {
        switch (previous.writeChange, writeChange) {
        case (nil, nil):
            true
        case let (previous?, current?):
            previous == current
        case (nil, _?):
            previous.state == .prepared && state != .prepared
        case (_?, nil):
            false
        }
    }

    private static func hasValidWriteChange(
        _ writeChange: WorkChange?,
        planned: WorkChange,
        state: WorkState
    ) -> Bool {
        guard let writeChange else { return true }
        return state != .prepared && writeChange.isValidReconciliation(of: planned)
    }

    private static func canTransition(from state: WorkState, to nextState: WorkState) -> Bool {
        switch (state, nextState) {
        case (.prepared, .attempting),
             (.attempting, .attempted),
             (.attempted, .outcome):
            true
        case let (.prepared, .outcome(outcome)):
            outcome != .written
        // `.attempting` carries no confirmed dispatch outcome: a crash can leave it before
        // dispatch or after dispatch but before `.attempted` persists. Recovery may record a
        // non-written closure such as `.dismissed`; `.written` still requires `.attempted`.
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
