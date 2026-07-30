import Foundation
import OSLog
import SwiftData

@ModelActor
public actor RunRecordDataStore: RunRecordStore {
    let log = Logger(subsystem: "com.genreupdater", category: "RunRecordStore")

    public func upsert(_ record: RunRecord) async throws {
        do {
            try Self.validateRecord(record)
            let targetID = record.runID.rawValue
            var descriptor = FetchDescriptor<PersistedRunRecord>(
                predicate: #Predicate { $0.runID == targetID }
            )
            descriptor.fetchLimit = 1

            if let existing = try modelContext.fetch(descriptor).first {
                // Existing state must remain readable so immutable run identity cannot be silently replaced.
                let stored = try makeRecord(from: existing)
                if let changedField = Self.changedHeaderField(from: stored, to: record) {
                    throw RunRecordPersistenceError.invalidField(name: changedField, runID: targetID)
                }
                try apply(record, to: existing)
            } else {
                try modelContext.insert(makePersisted(from: record))
            }
            try synchronizeWorkItems(for: record)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    public func loadAll() async throws -> [RunRecord] {
        let descriptor = FetchDescriptor<PersistedRunRecord>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map { try makeRecord(from: $0) }
    }

    public func record(for runID: RunID) async throws -> RunRecord? {
        let targetID = runID.rawValue
        var descriptor = FetchDescriptor<PersistedRunRecord>(
            predicate: #Predicate { $0.runID == targetID }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.map { try makeRecord(from: $0) }
    }

    public func prune(keepingLatest limit: Int) async throws -> Int {
        // limit < 1 is a no-op: an unclamped config value must not wipe the whole history.
        guard limit >= 1 else { return 0 }

        let descriptor = FetchDescriptor<PersistedRunRecord>(
            predicate: #Predicate { $0.finishedAt != nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        let terminalRecords = try modelContext.fetch(descriptor).filter(isPrunable)
        guard terminalRecords.count > limit else { return 0 }

        let excess = terminalRecords[limit...]
        for row in excess {
            modelContext.delete(row)
        }
        try saveOrRollback()
        log.info("""
        Pruned \(excess.count, privacy: .public) run records beyond the history limit of \
        \(limit, privacy: .public)
        """)
        return excess.count
    }

    private func makePersisted(from record: RunRecord) throws -> PersistedRunRecord {
        try PersistedRunRecord(
            record: record,
            scopeData: JSONEncoder().encode(record.scope),
            payloadData: JSONEncoder().encode(RunRecordPayload(record: record))
        )
    }

    func apply(_ record: RunRecord, to persisted: PersistedRunRecord) throws {
        persisted.requestID = record.requestID.rawValue
        persisted.triggerRaw = record.trigger.rawValue
        persisted.intentRaw = record.intent.rawValue
        persisted.stateRaw = record.state.rawValue
        persisted.writeAuthorityRaw = record.configuration?.writeAuthority.rawValue
        persisted.scopeData = try JSONEncoder().encode(record.scope)
        persisted.transitionsData = try JSONEncoder().encode(RunRecordPayload(record: record))
        persisted.syncNewCount = record.syncSummary?.new
        persisted.syncModifiedCount = record.syncSummary?.modified
        persisted.syncIdentityChangedCount = record.syncSummary?.identityChanged
        persisted.syncRefreshedCount = record.syncSummary?.refreshed
        persisted.syncRemovedCount = record.syncSummary?.removed
        persisted.failureMessage = record.failureMessage
        persisted.startedAt = record.startedAt
        persisted.finishedAt = record.finishedAt
    }

    func makeRecord(from persisted: PersistedRunRecord, loadsStoredWorkItems: Bool = true) throws -> RunRecord {
        guard let trigger = RunTrigger(rawValue: persisted.triggerRaw) else {
            throw RunRecordPersistenceError.corruptedField(name: "trigger", runID: persisted.runID)
        }
        guard let intent = RunIntent(rawValue: persisted.intentRaw) else {
            throw RunRecordPersistenceError.corruptedField(name: "intent", runID: persisted.runID)
        }

        let scope: ProcessingScopeSnapshot
        do {
            scope = try JSONDecoder().decode(ProcessingScopeSnapshot.self, from: persisted.scopeData)
        } catch {
            // Decode details stay private: scopeData embeds user artist names.
            log.error("""
            Corrupted scope blob in run record \(persisted.runID.uuidString, privacy: .public): \
            \(error.localizedDescription, privacy: .private)
            """)
            throw RunRecordPersistenceError.corruptedField(name: "scope", runID: persisted.runID)
        }

        let payload = try RunPayloadCodec.decode(from: persisted)
        try Self.validatePayload(payload, persisted: persisted, scope: scope, intent: intent)
        let workItems: [RunWorkItem] = if loadsStoredWorkItems {
            try loadWorkItems(for: persisted.runID, fallback: payload.workItems)
        } else {
            payload.workItems
        }
        let workLedger = WorkLedger(workItems)
        guard !workLedger.hasDuplicateItems,
              !(persisted.finishedAt != nil && workLedger.hasOpenItems)
        else {
            throw RunRecordPersistenceError.corruptedField(name: "workItems", runID: persisted.runID)
        }
        guard !Self.hasInvalidWorkAuthority(
            workItems,
            intent: intent,
            configuration: payload.configuration
        ) else {
            throw RunRecordPersistenceError.corruptedField(name: "workItems", runID: persisted.runID)
        }

        let syncSummary = decodeSyncSummary(from: persisted)

        return RunRecord(
            persisted: persisted,
            trigger: trigger,
            intent: intent,
            scope: scope,
            payload: payload,
            workLedger: workLedger,
            syncSummary: syncSummary
        )
    }

    private func saveOrRollback() throws {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}

extension RunRecord {
    fileprivate init(
        persisted: PersistedRunRecord,
        trigger: RunTrigger,
        intent: RunIntent,
        scope: ProcessingScopeSnapshot,
        payload: RunRecordPayload,
        workLedger: WorkLedger,
        syncSummary: ActivitySyncSummary?
    ) {
        runID = RunID(rawValue: persisted.runID)
        requestID = RunRequestID(rawValue: persisted.requestID)
        self.trigger = trigger
        self.intent = intent
        self.scope = scope
        configuration = payload.configuration
        writeTarget = payload.writeTarget
        recoveryID = payload.recoveryID
        transitions = payload.transitions
        self.workLedger = workLedger
        self.syncSummary = syncSummary
        writeSummary = payload.writeSummary
        failureMessage = persisted.failureMessage
        startedAt = persisted.startedAt
        finishedAt = persisted.finishedAt
    }
}
