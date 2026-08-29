import Foundation
import HashTreeCollections

struct WorkLedger: Equatable, Sendable {
    private struct Counts: Equatable, Sendable {
        var open = 0
        var uncertain = 0
        var written = 0

        init(_ items: [RunWorkItem]) {
            for item in items {
                update(item.state, by: 1)
            }
        }

        mutating func replace(_ current: WorkState, with next: WorkState) {
            update(current, by: -1)
            update(next, by: 1)
        }

        private mutating func update(_ state: WorkState, by change: Int) {
            switch state {
            case .prepared:
                open += change
            case .attempting, .attempted:
                open += change
                uncertain += change
            case .outcome(.written):
                written += change
            case .outcome:
                break
            }
        }
    }

    private let orderedIDs: [UUID]
    private var itemsByID: TreeDictionary<UUID, RunWorkItem>
    private let invalidItems: [RunWorkItem]?
    private let duplicateItemID: UUID?
    private var counts: Counts

    init(_ items: [RunWorkItem]) {
        var itemIDs: Set<UUID> = []
        var indexed: TreeDictionary<UUID, RunWorkItem> = [:]
        var duplicateItemID: UUID?
        for item in items {
            if !itemIDs.insert(item.id).inserted, duplicateItemID == nil {
                duplicateItemID = item.id
            }
            indexed[item.id] = item
        }
        orderedIDs = items.map(\.id)
        itemsByID = indexed
        invalidItems = duplicateItemID == nil ? nil : items
        self.duplicateItemID = duplicateItemID
        counts = Counts(items)
    }

    var items: [RunWorkItem] {
        if let invalidItems {
            return invalidItems
        }
        return orderedIDs.map { itemID in
            guard let item = itemsByID[itemID] else {
                preconditionFailure("Work ledger lost item \(itemID.uuidString)")
            }
            return item
        }
    }

    var hasDuplicateItems: Bool {
        duplicateItemID != nil
    }

    var hasUncertainty: Bool {
        counts.uncertain > 0
    }

    /// Recovery must observe both interrupted writes and legacy no-op outcomes
    /// that predate persisted write effects. A user-acknowledged legacy item is
    /// retained for audit but no longer blocks recovery clearance.
    var requiresRecoveryObservation: Bool {
        hasUncertainty || items.contains {
            $0.isLegacyNoOpMissingWriteEvidence || $0.isRecoveryAcknowledgementRequired
        }
    }

    var hasProgress: Bool {
        hasUncertainty || counts.written > 0
    }

    var hasOpenItems: Bool {
        counts.open > 0
    }

    func isWriteAdjacent(to checkpoint: WorkCheckpoint) -> Bool {
        if let invalidItems {
            return invalidItems.contains { item in
                checkpoint.states[item.id] != nil && item.state.isWriteUncertain
            }
        }
        return checkpoint.states.keys.contains { itemID in
            itemsByID[itemID]?.state.isWriteUncertain == true
        }
    }

    func applying(_ checkpoint: WorkCheckpoint) throws -> Self {
        let writeAdjacent = isWriteAdjacent(to: checkpoint)
        if let duplicateItemID {
            throw WorkCheckpointError.invalid(
                checkpoint.boundary,
                writeAdjacent: writeAdjacent,
                reason: "duplicate work item \(duplicateItemID.uuidString)"
            )
        }

        var transitions: [(UUID, RunWorkItem, RunWorkItem)] = []
        transitions.reserveCapacity(checkpoint.states.count)
        do {
            for (itemID, state) in checkpoint.states {
                guard let current = itemsByID[itemID] else {
                    // A post-dispatch boundary cannot rule out that Music.app was
                    // reached, so an unknown item classifies write-adjacent (fail closed).
                    throw WorkCheckpointError.invalid(
                        checkpoint.boundary,
                        writeAdjacent: writeAdjacent || checkpoint.boundary != .beforeAttempt,
                        reason: "unknown work item \(itemID.uuidString)"
                    )
                }
                try transitions.append((
                    itemID,
                    current,
                    current.transition(
                        to: state,
                        detail: current.detail,
                        writeChange: checkpoint.writeChanges[itemID]
                    )
                ))
            }
        } catch let error as WorkCheckpointError {
            throw error
        } catch {
            throw WorkCheckpointError.invalid(
                checkpoint.boundary,
                writeAdjacent: writeAdjacent,
                reason: error.localizedDescription
            )
        }

        var updated = self
        for (itemID, current, next) in transitions {
            updated.itemsByID[itemID] = next
            updated.counts.replace(current.state, with: next.state)
        }
        return updated
    }

    /// Closes every open item with its observed physical outcome (ADR 0006).
    ///
    /// Unlike `dismissingOpenWork`, callers supply one observed outcome per
    /// open item; incomplete coverage is rejected so no uncertainty can be
    /// closed unobserved, and a `.written` observation for a never-dispatched
    /// `.prepared` item is rejected at the boundary. An `.attempting` item
    /// observed as `.written` passes through the attempt boundary first,
    /// because the observation proves the dispatched value is physically
    /// present. Observed values are retained as item audit details.
    func applyingObservedOutcomes(_ observed: [UUID: ObservedWorkOutcome]) throws -> Self {
        let openIDs = Set(items.compactMap { item -> UUID? in
            if case .outcome = item.state {
                return nil
            }
            return item.id
        })
        let uncovered = openIDs.subtracting(observed.keys)
        guard uncovered.isEmpty else {
            throw WorkCheckpointError.invalid(
                .afterVerification,
                writeAdjacent: true,
                reason: "observed outcomes missing for \(uncovered.count) open work item(s)"
            )
        }
        let openObserved = observed.filter { openIDs.contains($0.key) }
        let invalidWritten = items.contains { item in
            item.state == .prepared && openObserved[item.id]?.outcome == .written
        }
        guard !invalidWritten else {
            throw WorkCheckpointError.invalid(
                .afterVerification,
                writeAdjacent: true,
                reason: "a never-dispatched item cannot carry a written observation"
            )
        }
        let writtenAttempting = items
            .filter { $0.state == .attempting && openObserved[$0.id]?.outcome == .written }
            .map(\.id)
        var ledger = self
        if !writtenAttempting.isEmpty {
            ledger = try ledger.applying(.afterAttempt(writtenAttempting))
        }
        ledger = try ledger.applying(.afterVerification(openObserved.mapValues(\.outcome)))
        for (itemID, observation) in openObserved {
            guard let detail = observation.detail, let current = ledger.itemsByID[itemID] else { continue }
            ledger.itemsByID[itemID] = current.annotated(detail: detail)
        }
        return ledger
    }

    /// Terminal items eligible for a linked continuation run: definite
    /// non-landings only. `.written` landed, `.dismissed` is a user decision,
    /// and `.needsReview` requires review before any re-application.
    var continuableItems: [RunWorkItem] {
        items.filter { item in
            item.state == .outcome(.failed) || item.state == .outcome(.skipped)
        }
    }

    func dismissingOpenWork() throws -> Self {
        var outcomes: [UUID: WorkOutcome] = [:]
        for item in items {
            switch item.state {
            case .prepared, .attempting, .attempted:
                outcomes[item.id] = .dismissed
            case .outcome:
                break
            }
        }
        return try applying(.afterVerification(outcomes))
    }

    /// Dismisses exactly the chosen open items, recording the shared detail
    /// and the explicit user-decision timestamp (ADR 0006). Unknown and
    /// already-closed targets are rejected before any transition so a stale
    /// selection can never silently rewrite an existing closure's audit.
    func dismissingItems(_ ids: Set<UUID>, detail: String, at timestamp: Date) throws -> Self {
        for id in ids {
            guard let item = itemsByID[id] else {
                throw WorkCheckpointError.invalid(
                    .afterVerification,
                    writeAdjacent: true,
                    reason: "unknown work item \(id.uuidString)"
                )
            }
            if case .outcome = item.state {
                throw WorkCheckpointError.invalid(
                    .afterVerification,
                    writeAdjacent: false,
                    reason: "work item \(id.uuidString) is already closed"
                )
            }
        }
        let outcomes = Dictionary(uniqueKeysWithValues: ids.map { ($0, WorkOutcome.dismissed) })
        var ledger = try applying(.afterVerification(outcomes))
        for id in ids {
            guard let current = ledger.itemsByID[id] else { continue }
            ledger.itemsByID[id] = current.recordingDismissal(detail: detail, at: timestamp)
        }
        return ledger
    }

    func acknowledgingRecoveryNoOp(id: UUID, detail: String, at timestamp: Date) throws -> Self {
        guard let item = itemsByID[id] else {
            throw WorkCheckpointError.invalid(
                .afterVerification,
                writeAdjacent: true,
                reason: "unknown work item \(id.uuidString)"
            )
        }
        guard item.isRecoveryAcknowledgementRequired else {
            throw WorkCheckpointError.invalid(
                .afterVerification,
                writeAdjacent: false,
                reason: "work item \(id.uuidString) does not need recovery acknowledgement"
            )
        }
        var updated = self
        updated.itemsByID[id] = item.recordingRecoveryAcknowledgement(detail: detail, at: timestamp)
        return updated
    }

    func recordingRecoveryObservationBlocker(_ blocker: RecoveryObservationBlocker) throws -> Self {
        guard let item = itemsByID[blocker.itemID],
              item.state == .outcome(.noFixNeeded),
              item.dismissedAt == nil
        else {
            throw WorkCheckpointError.invalid(
                .afterVerification,
                writeAdjacent: true,
                reason: "recovery observation blocker does not match an unresolved no-op item"
            )
        }
        var updated = self
        updated.itemsByID[blocker.itemID] = item.recordingRecoveryObservationIssue(blocker.issue)
        return updated
    }

    func clearingRecoveryObservationIssues() -> Self {
        var updated = self
        for item in items where item.recoveryObservationIssue != nil {
            updated.itemsByID[item.id] = item.recordingRecoveryObservationIssue(nil)
        }
        return updated
    }
}

extension WorkState {
    var isWriteUncertain: Bool {
        self == .attempting || self == .attempted
    }
}
