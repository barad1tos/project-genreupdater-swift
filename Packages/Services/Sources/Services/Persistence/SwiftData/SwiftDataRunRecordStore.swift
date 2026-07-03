import Foundation
import SwiftData

public enum RunRecordPersistenceError: LocalizedError {
    case corruptedField(name: String, runID: UUID)

    public var errorDescription: String? {
        switch self {
        case let .corruptedField(name, runID):
            "Failed to decode run record \(runID.uuidString): corrupted field \(name)"
        }
    }
}

@ModelActor
public actor SwiftDataRunRecordStore: RunRecordStore {
    public func upsert(_ record: RunRecord) async throws {
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

    private func makePersisted(from record: RunRecord) throws -> PersistedRunRecord {
        try PersistedRunRecord(
            runID: record.runID.rawValue,
            requestID: record.requestID.rawValue,
            triggerRaw: record.trigger.rawValue,
            intentRaw: record.intent.rawValue,
            stateRaw: record.state.rawValue,
            scopeData: JSONEncoder().encode(record.scope),
            transitionsData: JSONEncoder().encode(record.transitions),
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
        persisted.transitionsData = try JSONEncoder().encode(record.transitions)
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

        let syncSummary: ActivitySyncSummary? = if let new = persisted.syncNewCount,
                                                   let modified = persisted.syncModifiedCount,
                                                   let identityChanged = persisted.syncIdentityChangedCount,
                                                   let refreshed = persisted.syncRefreshedCount,
                                                   let removed = persisted.syncRemovedCount {
            ActivitySyncSummary(
                new: new,
                modified: modified,
                identityChanged: identityChanged,
                refreshed: refreshed,
                removed: removed
            )
        } else {
            nil
        }

        return try RunRecord(
            runID: RunID(rawValue: persisted.runID),
            requestID: RunRequestID(rawValue: persisted.requestID),
            trigger: trigger,
            intent: intent,
            scope: JSONDecoder().decode(ProcessingScopeSnapshot.self, from: persisted.scopeData),
            transitions: JSONDecoder().decode([RunLifecycleTransition].self, from: persisted.transitionsData),
            syncSummary: syncSummary,
            failureMessage: persisted.failureMessage,
            startedAt: persisted.startedAt,
            finishedAt: persisted.finishedAt
        )
    }
}
