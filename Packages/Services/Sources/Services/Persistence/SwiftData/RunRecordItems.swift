import Foundation
import SwiftData

private typealias CheckpointItem = (row: PersistedRunWorkItem, item: RunWorkItem, state: WorkState)

extension RunRecordDataStore {
    public func checkpoint(_ checkpoint: WorkCheckpoint, runID: RunID) async throws {
        do {
            try requireCheckpointRun(runID, boundary: checkpoint.boundary)
            let items = try loadCheckpointItems(checkpoint, runID: runID)
            try updateCheckpointItems(items, boundary: checkpoint.boundary)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func requireCheckpointRun(_ runID: RunID, boundary: CheckpointBoundary) throws {
        let rawRunID = runID.rawValue
        var descriptor = FetchDescriptor<PersistedRunRecord>(
            predicate: #Predicate { $0.runID == rawRunID }
        )
        descriptor.fetchLimit = 1
        guard let row = try modelContext.fetch(descriptor).first else {
            throw RunRecordPersistenceError.invalidField(name: "checkpoint.runID", runID: rawRunID)
        }
        guard row.intentRaw == RunIntent.writeFixes.rawValue,
              row.writeAuthorityRaw == WriteAuthority.reviewedPlan.rawValue,
              row.stateRaw == RunLifecycleState.writing.rawValue,
              row.finishedAt == nil
        else {
            throw WorkCheckpointError.invalid(
                boundary,
                writeAdjacent: false,
                reason: "run is not an active reviewed write"
            )
        }
    }

    private func loadCheckpointItems(_ checkpoint: WorkCheckpoint, runID: RunID) throws -> [CheckpointItem] {
        try checkpoint.states.map { itemID, state in
            try loadCheckpointItem(itemID, state: state, runID: runID)
        }
    }

    private func loadCheckpointItem(_ itemID: UUID, state: WorkState, runID: RunID) throws -> CheckpointItem {
        let key = PersistedRunWorkItem.key(runID: runID.rawValue, itemID: itemID)
        var descriptor = FetchDescriptor<PersistedRunWorkItem>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1
        guard let row = try modelContext.fetch(descriptor).first else {
            throw RunRecordPersistenceError.invalidField(name: "checkpoint.itemID", runID: runID.rawValue)
        }
        guard row.runID == runID.rawValue, row.itemID == itemID, row.key == key else {
            throw RunRecordPersistenceError.corruptedField(name: "workItems", runID: runID.rawValue)
        }
        guard let item = try? JSONDecoder().decode(RunWorkItem.self, from: row.itemData), item.id == itemID else {
            throw RunRecordPersistenceError.corruptedField(name: "workItems", runID: runID.rawValue)
        }
        return (row, item, state)
    }

    private func updateCheckpointItems(_ items: [CheckpointItem], boundary: CheckpointBoundary) throws {
        let isWriteAdjacent = items.contains { $0.item.state == .attempting || $0.item.state == .attempted }
        do {
            for item in items {
                item.row.itemData = try JSONEncoder().encode(item.item.transition(to: item.state))
            }
        } catch {
            throw WorkCheckpointError.invalid(
                boundary,
                writeAdjacent: isWriteAdjacent,
                reason: error.localizedDescription
            )
        }
    }

    func synchronizeWorkItems(for record: RunRecord) throws {
        let runID = record.runID.rawValue
        let descriptor = FetchDescriptor<PersistedRunWorkItem>(
            predicate: #Predicate { $0.runID == runID }
        )
        let existing = try modelContext.fetch(descriptor)
        let workItems = record.workItems
        guard record.finishedAt == nil, !workItems.isEmpty else {
            existing.forEach(modelContext.delete)
            return
        }

        var rows = Dictionary(uniqueKeysWithValues: existing.map { ($0.itemID, $0) })
        for (position, item) in workItems.enumerated() {
            let data = try JSONEncoder().encode(item)
            if let row = rows.removeValue(forKey: item.id) {
                row.position = position
                row.itemData = data
            } else {
                modelContext.insert(PersistedRunWorkItem(
                    runID: runID,
                    itemID: item.id,
                    position: position,
                    itemData: data
                ))
            }
        }
        rows.values.forEach(modelContext.delete)
    }

    func loadWorkItems(for runID: UUID, fallback: [RunWorkItem]) throws -> [RunWorkItem] {
        let descriptor = FetchDescriptor<PersistedRunWorkItem>(
            predicate: #Predicate { $0.runID == runID },
            sortBy: [SortDescriptor(\.position)]
        )
        let rows = try modelContext.fetch(descriptor)
        guard !rows.isEmpty else { return fallback }
        guard rows.count == fallback.count else {
            throw RunRecordPersistenceError.corruptedField(name: "workItems", runID: runID)
        }

        var items: [RunWorkItem] = []
        do {
            for (position, row) in rows.enumerated() {
                let expected = fallback[position]
                let item = try JSONDecoder().decode(RunWorkItem.self, from: row.itemData)
                guard row.runID == runID,
                      row.position == position,
                      row.itemID == expected.id,
                      row.key == PersistedRunWorkItem.key(runID: runID, itemID: expected.id),
                      item.id == expected.id,
                      item.target == expected.target,
                      item.change == expected.change,
                      item.detail == expected.detail,
                      item.state.canFollow(expected.state)
                else {
                    throw RunRecordPersistenceError.corruptedField(name: "workItems", runID: runID)
                }
                items.append(item)
            }
        } catch let error as RunRecordPersistenceError {
            throw error
        } catch {
            throw RunRecordPersistenceError.corruptedField(name: "workItems", runID: runID)
        }
        return items
    }

    func deleteWorkItems(for runID: UUID) throws {
        let descriptor = FetchDescriptor<PersistedRunWorkItem>(
            predicate: #Predicate { $0.runID == runID }
        )
        try modelContext.fetch(descriptor).forEach(modelContext.delete)
    }
}
