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

    init(
        boundary: CheckpointBoundary,
        states: [UUID: WorkState],
        writeChanges: [UUID: WorkChange] = [:]
    ) {
        self.boundary = boundary
        self.states = states
        self.writeChanges = writeChanges
    }

    /// Carries the authoritative metadata effect into a durable write or no-op finalization checkpoint.
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

    public static func afterVerification(
        _ outcomes: [UUID: WorkOutcome],
        writeChanges: [UUID: WorkChange] = [:]
    ) -> Self {
        Self(
            boundary: .afterVerification,
            states: outcomes.mapValues(WorkState.outcome),
            writeChanges: writeChanges
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
    private enum CodingKeys: String, CodingKey {
        case changeType
        case oldValue
        case newValue
        case confidence
        case source
        case albumArtistChange
    }

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
        guard isSemanticallyValid,
              planned.isSemanticallyValid,
              changeType == planned.changeType,
              oldValue == planned.oldValue,
              newValue == planned.newValue,
              confidence == planned.confidence,
              source == planned.source
        else {
            return false
        }
        guard let albumArtistChange else { return true }
        guard let plannedAlbumEffect = planned.albumArtistChange else { return false }
        return normalizeForMatching(albumArtistChange.oldValue)
            == normalizeForMatching(plannedAlbumEffect.oldValue)
            && albumArtistChange.newValue == plannedAlbumEffect.newValue
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        changeType = try values.decode(ChangeType.self, forKey: .changeType)
        oldValue = try values.decodeIfPresent(String.self, forKey: .oldValue)
        newValue = try values.decodeIfPresent(String.self, forKey: .newValue)
        confidence = try values.decode(Int.self, forKey: .confidence)
        source = try values.decode(String.self, forKey: .source)
        albumArtistChange = try values.decodeIfPresent(AlbumArtistChange.self, forKey: .albumArtistChange)
        guard isSemanticallyValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .albumArtistChange,
                in: values,
                debugDescription: "Album-artist evidence contradicts the primary change"
            )
        }
    }

    fileprivate var isSemanticallyValid: Bool {
        guard let albumArtistChange else { return true }
        guard changeType == .artistRename,
              let oldValue,
              let newValue
        else {
            return false
        }
        return normalizeForMatching(albumArtistChange.oldValue) == normalizeForMatching(oldValue)
            && albumArtistChange.newValue == newValue
    }
}

/// One immutable unit of run planning and processing.
public struct RunWorkItem: Codable, Equatable, Sendable, Identifiable {
    static let evidenceVersion = 1

    private enum CodingKeys: String, CodingKey {
        case id
        case target
        case change
        case writeChange
        case writeEvidenceVersion
        case hasWriteEvidence
        case state
        case detail
        case dismissedAt
    }

    public let id: UUID
    public let target: WorkTarget
    public let change: WorkChange
    /// Authoritative metadata effect persisted before dispatch or when a no-op
    /// is verified. Nil means the item has not crossed either boundary, or
    /// predates this evidence.
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
        let writeChange: WorkChange? = switch state {
        case .attempting, .attempted, .outcome(.written):
            change
        case .prepared, .outcome:
            nil
        }
        self.init(
            id: id,
            target: target,
            change: change,
            state: state,
            detail: detail,
            dismissedAt: dismissedAt,
            writeChange: writeChange
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
        let evidenceVersion = try values.decodeIfPresent(Int.self, forKey: .writeEvidenceVersion)
        let hasWriteEvidence = try values.decodeIfPresent(Bool.self, forKey: .hasWriteEvidence)
        let state = try values.decode(WorkState.self, forKey: .state)
        guard Self.hasValidEvidenceMarker(
            version: evidenceVersion,
            hasWriteEvidence: hasWriteEvidence,
            writeChange: writeChange
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .writeEvidenceVersion,
                in: values,
                debugDescription: "Write evidence marker is incomplete, unsupported, or contradicts the encoded effect"
            )
        }
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

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(target, forKey: .target)
        try values.encode(change, forKey: .change)
        try values.encodeIfPresent(writeChange, forKey: .writeChange)
        try values.encode(Self.evidenceVersion, forKey: .writeEvidenceVersion)
        try values.encode(writeChange != nil, forKey: .hasWriteEvidence)
        try values.encode(state, forKey: .state)
        try values.encodeIfPresent(detail, forKey: .detail)
        try values.encodeIfPresent(dismissedAt, forKey: .dismissedAt)
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
            let capturesNoOp = nextState == .outcome(.noFixNeeded)
            guard suppliedWriteChange.isValidReconciliation(of: change),
                  writeChange != nil || nextState == .attempting || capturesNoOp
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
            writeChange: writeChange ?? suppliedWriteChange ?? (nextState == .attempting ? change : nil)
        )
    }

    var effectiveChange: WorkChange {
        writeChange ?? change
    }

    var isWriteEvidenceComplete: Bool {
        switch state {
        case .attempting, .attempted, .outcome(.written):
            writeChange != nil
        case .prepared, .outcome:
            true
        }
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
        guard planned.isSemanticallyValid else { return false }
        guard let writeChange else { return true }
        return state != .prepared && writeChange.isValidReconciliation(of: planned)
    }

    private static func hasValidEvidenceMarker(
        version: Int?,
        hasWriteEvidence: Bool?,
        writeChange: WorkChange?
    ) -> Bool {
        switch (version, hasWriteEvidence) {
        case (nil, nil):
            true
        case (evidenceVersion, let hasWriteEvidence?):
            hasWriteEvidence == (writeChange != nil)
        default:
            false
        }
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

struct CurrentWorkItemPayload: Decodable {
    private enum CodingKeys: String, CodingKey {
        case writeEvidenceVersion
        case hasWriteEvidence
    }

    let item: RunWorkItem

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let evidenceVersion = try values.decode(Int.self, forKey: .writeEvidenceVersion)
        let hasWriteEvidence = try values.decode(Bool.self, forKey: .hasWriteEvidence)
        item = try RunWorkItem(from: decoder)
        guard evidenceVersion == RunWorkItem.evidenceVersion,
              hasWriteEvidence == (item.writeChange != nil),
              item.isWriteEvidenceComplete
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .writeEvidenceVersion,
                in: values,
                debugDescription: "Current work item has incomplete write evidence"
            )
        }
    }
}
