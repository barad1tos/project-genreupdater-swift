import Foundation
import OSLog
import SwiftData

public enum RunRecordPersistenceError: LocalizedError {
    case corruptedField(name: String, runID: UUID)
    case unsupportedPayloadVersion(version: Int, runID: UUID)

    public var errorDescription: String? {
        switch self {
        case let .corruptedField(name, runID):
            "Failed to decode run record \(runID.uuidString): corrupted field \(name)"
        case let .unsupportedPayloadVersion(version, runID):
            "Cannot decode run record \(runID.uuidString): unsupported payload version \(version)"
        }
    }
}

private struct RunRecordPayload: Codable {
    // Stored in the legacy transitionsData column to avoid a SwiftData schema migration.
    let version: Int
    let transitions: [RunLifecycleTransition]
    let writeTarget: FixPlanWriteTarget?
    let recoveryID: UUID?
    let writeSummary: RunWriteSummary?

    init(record: RunRecord) {
        version = 1
        transitions = record.transitions
        writeTarget = record.writeTarget
        recoveryID = record.recoveryID
        writeSummary = record.writeSummary
    }

    init(
        version: Int,
        transitions: [RunLifecycleTransition],
        writeTarget: FixPlanWriteTarget?,
        recoveryID: UUID?,
        writeSummary: RunWriteSummary?
    ) {
        self.version = version
        self.transitions = transitions
        self.writeTarget = writeTarget
        self.recoveryID = recoveryID
        self.writeSummary = writeSummary
    }
}

private struct RunRecordPayloadVersion: Decodable {
    let version: Int
}

@ModelActor
public actor RunRecordDataStore: RunRecordStore {
    private let log = Logger(subsystem: "com.genreupdater", category: "RunRecordStore")

    public func upsert(_ record: RunRecord) async throws {
        do {
            let targetID = record.runID.rawValue
            var descriptor = FetchDescriptor<PersistedRunRecord>(
                predicate: #Predicate { $0.runID == targetID }
            )
            descriptor.fetchLimit = 1

            if let existing = try modelContext.fetch(descriptor).first {
                try apply(record, to: existing)
            } else {
                try modelContext.insert(makePersisted(from: record))
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

        let descriptor = FetchDescriptor<PersistedRunRecord>(
            predicate: #Predicate { $0.finishedAt != nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        let terminalRecords = try modelContext.fetch(descriptor)
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

    public func recoveryRecords() async throws -> RunReportPage {
        let descriptor = FetchDescriptor<PersistedRunRecord>(
            predicate: #Predicate { $0.finishedAt == nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        return try makePage(from: modelContext.fetch(descriptor), including: Self.mayNeedRecovery)
    }

    public func claimRecovery(for runID: RunID, id recoveryID: UUID, at timestamp: Date) async throws -> UUID? {
        do {
            let targetID = runID.rawValue
            var descriptor = FetchDescriptor<PersistedRunRecord>(
                predicate: #Predicate { $0.runID == targetID }
            )
            descriptor.fetchLimit = 1
            guard let row = try modelContext.fetch(descriptor).first else { return nil }
            let record = try makeRecord(from: row)
            guard record.finishedAt == nil,
                  record.intent == .writeFixes,
                  record.state.needsWriteRecovery
            else { return nil }
            if let claimedID = record.recoveryID {
                return claimedID
            }

            try apply(record.openingRecovery(id: recoveryID, at: timestamp), to: row)
            try modelContext.save()
            return recoveryID
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    public func closeCorruptedRun(_ runID: RunID, at finishedAt: Date) async throws -> Bool {
        do {
            let targetID = runID.rawValue
            var descriptor = FetchDescriptor<PersistedRunRecord>(
                predicate: #Predicate { $0.runID == targetID }
            )
            descriptor.fetchLimit = 1
            guard let row = try modelContext.fetch(descriptor).first,
                  row.finishedAt == nil
            else { return false }
            if let intent = RunIntent(rawValue: row.intentRaw), intent != .writeFixes {
                return false
            }
            let payload: RunRecordPayload?
            do {
                payload = try decodePayload(from: row)
            } catch RunRecordPersistenceError.unsupportedPayloadVersion {
                return false
            } catch {
                payload = nil
            }
            if row.stateRaw == RunLifecycleState.blocked.rawValue
                || payload?.transitions.last?.state == .blocked {
                return false
            }
            do {
                _ = try makeRecord(from: row)
                return false
            } catch is RunRecordPersistenceError {
                let scope = (try? JSONDecoder().decode(ProcessingScopeSnapshot.self, from: row.scopeData))
                    ?? ProcessingScopeSnapshot.capture(
                        requestedTestArtists: [],
                        knownTrackCount: nil,
                        createdAt: row.startedAt,
                        reason: RunTrigger.recovery.rawValue
                    )
                var transitions = payload?.transitions ?? []
                if transitions.last?.state != .recovering {
                    transitions.append(RunLifecycleTransition(state: .recovering, timestamp: finishedAt))
                }
                transitions.append(RunLifecycleTransition(state: .cancelled, timestamp: finishedAt))

                row.triggerRaw = RunTrigger(rawValue: row.triggerRaw)?.rawValue ?? RunTrigger.recovery.rawValue
                row.intentRaw = RunIntent.writeFixes.rawValue
                row.stateRaw = RunLifecycleState.cancelled.rawValue
                row.scopeData = try JSONEncoder().encode(scope)
                row.transitionsData = try JSONEncoder().encode(RunRecordPayload(
                    version: 1,
                    transitions: transitions,
                    writeTarget: payload?.writeTarget,
                    recoveryID: payload?.recoveryID ?? row.runID,
                    writeSummary: payload?.writeSummary
                ))
                row.failureMessage = Self.corruptedRecoveryMessage(existing: row.failureMessage)
                row.finishedAt = finishedAt
            }
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    public func reports(matching query: RunReportQuery) async throws -> RunReportPage {
        let after = query.startedAfter ?? Date.distantPast
        let before = query.startedBefore ?? Date.distantFuture
        let stateFilter = Set((query.states ?? []).map(\.rawValue))
        let filtersState = !stateFilter.isEmpty
        let triggerFilter = query.trigger?.rawValue ?? ""
        let filtersTrigger = !triggerFilter.isEmpty

        var descriptor = FetchDescriptor<PersistedRunRecord>(
            predicate: #Predicate { row in
                row.startedAt >= after && row.startedAt <= before
                    && (!filtersState || stateFilter.contains(row.stateRaw))
                    && (!filtersTrigger || row.triggerRaw == triggerFilter)
            },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        if let limit = query.limit, limit > 0 {
            descriptor.fetchLimit = limit
        }

        return try makePage(from: modelContext.fetch(descriptor))
    }

    private func makePage(
        from rows: [PersistedRunRecord],
        including shouldInclude: (PersistedRunRecord) -> Bool = { _ in true }
    ) throws -> RunReportPage {
        var records: [RunRecord] = []
        var corruptedRunIDs: [RunID] = []
        var recoveryRunIDs: [RunID] = []
        var skippedCorruptedCount = 0
        for row in rows where shouldInclude(row) {
            do {
                try records.append(makeRecord(from: row))
            } catch let error as RunRecordPersistenceError {
                skippedCorruptedCount += 1
                corruptedRunIDs.append(RunID(rawValue: row.runID))
                if row.finishedAt == nil, Self.mayNeedRecovery(row) {
                    recoveryRunIDs.append(RunID(rawValue: row.runID))
                }
                log.error("""
                Skipping corrupted run record \(row.runID.uuidString, privacy: .public) \
                in report query: \(error.localizedDescription, privacy: .public)
                """)
            }
        }

        return RunReportPage(
            records: records,
            skippedCorruptedCount: skippedCorruptedCount,
            corruptedRunIDs: corruptedRunIDs,
            recoveryRunIDs: recoveryRunIDs
        )
    }

    private static func mayNeedRecovery(_ row: PersistedRunRecord) -> Bool {
        guard let intent = RunIntent(rawValue: row.intentRaw) else { return true }
        return intent == .writeFixes
    }

    private func makePersisted(from record: RunRecord) throws -> PersistedRunRecord {
        try PersistedRunRecord(
            runID: record.runID.rawValue,
            requestID: record.requestID.rawValue,
            triggerRaw: record.trigger.rawValue,
            intentRaw: record.intent.rawValue,
            stateRaw: record.state.rawValue,
            scopeData: JSONEncoder().encode(record.scope),
            transitionsData: JSONEncoder().encode(RunRecordPayload(record: record)),
            syncNewCount: record.syncSummary?.new,
            syncModifiedCount: record.syncSummary?.modified,
            syncIdentityChangedCount: record.syncSummary?.identityChanged,
            syncRefreshedCount: record.syncSummary?.refreshed,
            syncRemovedCount: record.syncSummary?.removed,
            failureMessage: record.failureMessage,
            startedAt: record.startedAt,
            finishedAt: record.finishedAt
        )
    }

    private func apply(_ record: RunRecord, to persisted: PersistedRunRecord) throws {
        persisted.requestID = record.requestID.rawValue
        persisted.triggerRaw = record.trigger.rawValue
        persisted.intentRaw = record.intent.rawValue
        persisted.stateRaw = record.state.rawValue
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

    private func makeRecord(from persisted: PersistedRunRecord) throws -> RunRecord {
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

        let payload = try decodePayload(from: persisted)
        // An empty transitions list would otherwise decode as a fake `.created` record (see RunRecord.state).
        guard !payload.transitions.isEmpty else {
            throw RunRecordPersistenceError.corruptedField(name: "transitions", runID: persisted.runID)
        }

        let syncSummary = decodeSyncSummary(from: persisted)

        return RunRecord(
            runID: RunID(rawValue: persisted.runID),
            requestID: RunRequestID(rawValue: persisted.requestID),
            trigger: trigger,
            intent: intent,
            scope: scope,
            writeTarget: payload.writeTarget,
            recoveryID: payload.recoveryID,
            transitions: payload.transitions,
            syncSummary: syncSummary,
            writeSummary: payload.writeSummary,
            failureMessage: persisted.failureMessage,
            startedAt: persisted.startedAt,
            finishedAt: persisted.finishedAt
        )
    }

    private func decodeSyncSummary(from persisted: PersistedRunRecord) -> ActivitySyncSummary? {
        guard let new = persisted.syncNewCount,
              let modified = persisted.syncModifiedCount,
              let identityChanged = persisted.syncIdentityChangedCount,
              let refreshed = persisted.syncRefreshedCount,
              let removed = persisted.syncRemovedCount
        else { return nil }

        return ActivitySyncSummary(
            new: new,
            modified: modified,
            identityChanged: identityChanged,
            refreshed: refreshed,
            removed: removed
        )
    }

    private func decodePayload(from persisted: PersistedRunRecord) throws -> RunRecordPayload {
        do {
            let decoder = JSONDecoder()
            let payloadVersion = try decoder.decode(
                RunRecordPayloadVersion.self,
                from: persisted.transitionsData
            ).version
            guard payloadVersion == 1 else {
                throw RunRecordPersistenceError.unsupportedPayloadVersion(
                    version: payloadVersion,
                    runID: persisted.runID
                )
            }
            return try decoder.decode(RunRecordPayload.self, from: persisted.transitionsData)
        } catch let error as RunRecordPersistenceError {
            throw error
        } catch {
            return try decodeLegacyPayload(from: persisted)
        }
    }

    private func decodeLegacyPayload(from persisted: PersistedRunRecord) throws -> RunRecordPayload {
        do {
            let transitions = try JSONDecoder().decode([RunLifecycleTransition].self, from: persisted.transitionsData)
            return RunRecordPayload(
                version: 1,
                transitions: transitions,
                writeTarget: nil,
                recoveryID: nil,
                writeSummary: nil
            )
        } catch {
            log.error("""
            Corrupted transitions blob in run record \(persisted.runID.uuidString, privacy: .public): \
            \(error.localizedDescription, privacy: .private)
            """)
            throw RunRecordPersistenceError.corruptedField(name: "transitions", runID: persisted.runID)
        }
    }

    private func saveOrRollback() throws {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private static func corruptedRecoveryMessage(existing: String?) -> String {
        let closure = "Recovery closed after Music.app verification; the stored run payload was corrupted."
        return existing.map { "\($0) \(closure)" } ?? closure
    }
}
