import Foundation
import HashTreeCollections

struct WorkLedger: Equatable, Sendable {
    private struct Counts: Equatable, Sendable {
        var open = 0
        var uncertain = 0
        var dispatched = 0
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
            case .attempting:
                open += change
                uncertain += change
            case .attempted:
                open += change
                uncertain += change
                dispatched += change
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

    var hasUncertainty: Bool {
        counts.uncertain > 0
    }

    /// True once at least one write was actually dispatched to Music.app (an `.attempted` item).
    /// Distinct from `hasUncertainty`, which also covers `.attempting` items that never dispatched.
    var hasDispatchedWrite: Bool {
        counts.dispatched > 0
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
                    throw WorkCheckpointError.invalid(
                        checkpoint.boundary,
                        writeAdjacent: writeAdjacent,
                        reason: "unknown work item \(itemID.uuidString)"
                    )
                }
                try transitions.append((itemID, current, current.transition(to: state)))
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
}

extension WorkState {
    fileprivate var isWriteUncertain: Bool {
        self == .attempting || self == .attempted
    }
}
