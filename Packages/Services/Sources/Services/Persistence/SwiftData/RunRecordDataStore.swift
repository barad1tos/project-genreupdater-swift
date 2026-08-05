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
            if record.finishedAt != nil {
                try upsertReportItems(
                    runID: record.runID.rawValue,
                    startedAt: record.startedAt,
                    items: record.workItems
                )
            }
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

        // Open rows are never deletion candidates, but they contribute
        // continuation references, so the pass walks every record. References
        // flow newer -> older (a continuation is constructible only after its
        // source closed), so one descending pass sees every referencer before
        // its source; the disjointness guard below fails closed if a clock
        // step ever breaks that ordering.
        let descriptor = FetchDescriptor<PersistedRunRecord>(
            sortBy: [
                SortDescriptor(\.startedAt, order: .reverse),
                SortDescriptor(\.runID),
            ]
        )
        // Mirrors upsert: any throw after the first delete must roll back,
        // or the pending deletions would silently commit with the next
        // unrelated save on this actor's long-lived context.
        do {
            let pass = try stageDeletions(keepingLatest: limit, descriptor: descriptor)
            let collidedRunIDs = pass.referencedRunIDs.intersection(pass.deletedRunIDs)
            guard collidedRunIDs.isEmpty else {
                modelContext.rollback()
                let collided = collidedRunIDs.map(\.uuidString).sorted().joined(separator: ", ")
                log.error("""
                Run history pruning aborted: retained runs reference run(s) \
                scheduled for deletion [\(collided, privacy: .public)] — \
                startedAt ordering no longer matches continuation lineage. \
                Nothing was deleted.
                """)
                return 0
            }
            guard !pass.deletedRunIDs.isEmpty else {
                logProtectedOverflow(pass.retainedProtectedCount)
                return 0
            }
            try modelContext.save()
            logProtectedOverflow(pass.retainedProtectedCount)
            log.info("""
            Pruned \(pass.deletedRunIDs.count, privacy: .public) run records beyond the history limit of \
            \(limit, privacy: .public)
            """)
            return pass.deletedRunIDs.count
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private struct PrunePass {
        var referencedRunIDs = Set<UUID>()
        var consumedSourceIDs = Set<UUID>()
        var deletedRunIDs = Set<UUID>()
        var retainedPrunableCount = 0
        var retainedProtectedCount = 0
    }

    private func stageDeletions(
        keepingLatest limit: Int,
        descriptor: FetchDescriptor<PersistedRunRecord>
    ) throws -> PrunePass {
        var pass = PrunePass()
        for row in try modelContext.fetch(descriptor) {
            let record = try? makeRecord(from: row)
            // A terminal continuation that finished with nothing unresolved
            // has consumed its source's continuation precondition — the
            // source's failed/skipped items were re-applied or explicitly
            // closed by the user (visited before the source in descending
            // order).
            if let record, row.finishedAt != nil, let consumed = record.continuesRunID,
               !record.hasUnresolvedEvidence {
                pass.consumedSourceIDs.insert(consumed.rawValue)
            }
            // Explicit statements, not a `&&` chain: the operator's autoclosure
            // would capture the non-Sendable row and trip strict concurrency
            // on newer toolchains (CI-only).
            var isDeletionCandidate = false
            if row.finishedAt != nil, !pass.referencedRunIDs.contains(row.runID) {
                isDeletionCandidate = isPrunable(
                    row,
                    record: record,
                    isEvidenceConsumed: pass.consumedSourceIDs.contains(row.runID)
                )
            }
            if isDeletionCandidate, pass.retainedPrunableCount >= limit {
                try deleteWorkItems(for: row.runID)
                try deleteReportItems(for: row.runID)
                modelContext.delete(row)
                pass.deletedRunIDs.insert(row.runID)
                continue
            }
            if isDeletionCandidate {
                pass.retainedPrunableCount += 1
            } else if row.finishedAt != nil {
                pass.retainedProtectedCount += 1
            }
            if let reference = continuationReference(of: row, record: record) {
                pass.referencedRunIDs.insert(reference)
            }
        }
        return pass
    }

    private func logProtectedOverflow(_ retainedProtectedCount: Int) {
        guard retainedProtectedCount > 0 else { return }
        log.info("""
        Retention kept \(retainedProtectedCount, privacy: .public) protected terminal run record(s) on \
        top of the history limit (unresolved evidence, corrupted fail-closed retention, or referenced \
        by a retained run)
        """)
    }

    private func continuationReference(of row: PersistedRunRecord, record: RunRecord?) -> UUID? {
        if let record {
            return record.continuesRunID?.rawValue
        }
        do {
            let decoded = try RunPayloadCodec.decodeForRecovery(from: row)
            guard decoded.payload != nil || decoded.fallback != nil else {
                // Garbage bytes: decodeForRecovery returns (nil, nil) without
                // throwing — the genuinely unreadable path.
                logUnreadableReference(of: row)
                return nil
            }
            return (decoded.payload?.continuesRunID ?? decoded.fallback?.continuesRunID)?.rawValue
        } catch {
            // Forward-schema payloads still salvage per-field: a v(N+1) row is
            // retained fail-closed, but its reference must keep protecting the
            // source it continues.
            if let salvage = try? JSONDecoder().decode(RecoveryPayload.self, from: row.transitionsData) {
                return salvage.continuesRunID?.rawValue
            }
            logUnreadableReference(of: row)
            return nil
        }
    }

    private func logUnreadableReference(of row: PersistedRunRecord) {
        log.error("""
        Run \(row.runID, privacy: .public) payload is unreadable; its continuation reference \
        (if any) cannot protect a source record from pruning
        """)
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
        persisted.recoveryIDRaw = record.recoveryID
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
        continuesRunID = payload.continuesRunID
        transitions = payload.transitions
        self.workLedger = workLedger
        self.syncSummary = syncSummary
        writeSummary = payload.writeSummary
        failureMessage = persisted.failureMessage
        startedAt = persisted.startedAt
        finishedAt = persisted.finishedAt
    }
}
