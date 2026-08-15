import Foundation
import SwiftData

private struct CheckpointItem {
    let row: PersistedRunWorkItem
    let item: RunWorkItem
    let state: WorkState
    let writeChange: WorkChange?
}

extension RunRecordDataStore {
    public func checkpoint(_ checkpoint: WorkCheckpoint, runID: RunID) async throws {
        do {
            let items = try loadCheckpointItems(checkpoint, runID: runID)
            let writeAdjacent = items.contains { $0.item.state == .attempting || $0.item.state == .attempted }
            try requireCheckpointRun(
                runID,
                boundary: checkpoint.boundary,
                writeAdjacent: writeAdjacent
            )
            try updateCheckpointItems(
                items,
                boundary: checkpoint.boundary,
                writeAdjacent: writeAdjacent
            )
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func requireCheckpointRun(
        _ runID: RunID,
        boundary: CheckpointBoundary,
        writeAdjacent: Bool
    ) throws {
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
                writeAdjacent: writeAdjacent,
                reason: "run is not an active reviewed write"
            )
        }
    }

    private func loadCheckpointItems(_ checkpoint: WorkCheckpoint, runID: RunID) throws -> [CheckpointItem] {
        try checkpoint.states.map { itemID, state in
            try loadCheckpointItem(
                itemID,
                state: state,
                writeChange: checkpoint.writeChanges[itemID],
                runID: runID
            )
        }
    }

    private func loadCheckpointItem(
        _ itemID: UUID,
        state: WorkState,
        writeChange: WorkChange?,
        runID: RunID
    ) throws -> CheckpointItem {
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
        return CheckpointItem(row: row, item: item, state: state, writeChange: writeChange)
    }

    private func updateCheckpointItems(
        _ items: [CheckpointItem],
        boundary: CheckpointBoundary,
        writeAdjacent: Bool
    ) throws {
        do {
            for item in items {
                item.row.itemData = try JSONEncoder().encode(item.item.transition(
                    to: item.state,
                    detail: item.item.detail,
                    writeChange: item.writeChange
                ))
            }
        } catch {
            throw WorkCheckpointError.invalid(
                boundary,
                writeAdjacent: writeAdjacent,
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

    func loadWorkItems(
        for runID: UUID,
        fallback: [RunWorkItem],
        requiresRows: Bool
    ) throws -> [RunWorkItem] {
        let descriptor = FetchDescriptor<PersistedRunWorkItem>(
            predicate: #Predicate { $0.runID == runID },
            sortBy: [SortDescriptor(\.position)]
        )
        let rows = try modelContext.fetch(descriptor)
        guard !rows.isEmpty else {
            guard !requiresRows else {
                throw RunRecordPersistenceError.corruptedField(name: "workItems", runID: runID)
            }
            return fallback
        }
        guard rows.count == fallback.count else {
            throw RunRecordPersistenceError.corruptedField(name: "workItems", runID: runID)
        }

        var items: [RunWorkItem] = []
        do {
            for (position, row) in rows.enumerated() {
                let expected = fallback[position]
                let item: RunWorkItem = if requiresRows {
                    try JSONDecoder().decode(
                        CurrentWorkItemPayload.self,
                        from: row.itemData
                    ).item
                } else {
                    try JSONDecoder().decode(RunWorkItem.self, from: row.itemData)
                }
                guard row.runID == runID,
                      row.position == position,
                      row.itemID == expected.id,
                      row.key == PersistedRunWorkItem.key(runID: runID, itemID: expected.id),
                      item.id == expected.id,
                      item.target == expected.target,
                      item.change == expected.change,
                      item.detail == expected.detail,
                      item.canReconcileWriteChange(from: expected),
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

    /// Mirrors the run's final work-item ledger into queryable report rows.
    /// Idempotent by unique key: a repair path may re-terminalize a run with
    /// a rebuilt ledger and the rows must follow — they never diverge from
    /// the payload ledger. (Plain upserts cannot change a terminal record's
    /// items — `changedTerminalField` rejects that — so refresh only ever
    /// comes from repairs.)
    func upsertReportItems(runID: UUID, startedAt: Date, items: [RunWorkItem]) throws {
        let descriptor = FetchDescriptor<PersistedRunReportItem>(
            predicate: #Predicate { $0.runID == runID }
        )
        var rows: [UUID: PersistedRunReportItem] = [:]
        for row in try modelContext.fetch(descriptor) {
            if rows[row.itemID] == nil {
                rows[row.itemID] = row
            } else {
                // Unrepresentable while the unique key holds; drop the
                // duplicate instead of trapping on an externally tampered store.
                log.error("""
                Dropping duplicate report item row \(row.key, privacy: .public)
                """)
                modelContext.delete(row)
            }
        }
        for (position, item) in items.enumerated() {
            let data = try JSONEncoder().encode(item)
            if let row = rows.removeValue(forKey: item.id) {
                row.apply(position: position, runStartedAt: startedAt, item: item, itemData: data)
            } else {
                modelContext.insert(PersistedRunReportItem(
                    runID: runID,
                    position: position,
                    runStartedAt: startedAt,
                    item: item,
                    itemData: data
                ))
            }
        }
        rows.values.forEach(modelContext.delete)
    }

    func deleteReportItems(for runID: UUID) throws {
        let descriptor = FetchDescriptor<PersistedRunReportItem>(
            predicate: #Predicate { $0.runID == runID }
        )
        try modelContext.fetch(descriptor).forEach(modelContext.delete)
    }

    /// Change-log entries follow their run's retention (user decision
    /// 2026-08-06): undo depth equals retained run history. Nil-runID rows
    /// (legacy and undo-revert entries) are never touched here.
    func deleteChangeLogEntries(for runID: UUID) throws {
        let descriptor = FetchDescriptor<PersistedChangeLogEntry>(
            predicate: #Predicate { $0.runID == runID }
        )
        try modelContext.fetch(descriptor).forEach(modelContext.delete)
    }
}
