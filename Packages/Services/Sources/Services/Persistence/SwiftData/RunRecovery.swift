import Foundation
import SwiftData

private struct DecodedRecovery {
    let row: PersistedRunRecord
    let payload: RunRecordPayload?
    let fallback: RecoveryPayload?
    let itemAudit: RecoveryItemAudit
}

extension RunRecordDataStore {
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
        try await closeCorruption(runID, at: finishedAt, isReadOnly: false)
    }

    public func closeReadOnlyCorruption(_ runID: RunID, at finishedAt: Date) async throws -> Bool {
        try await closeCorruption(runID, at: finishedAt, isReadOnly: true)
    }

    private func closeCorruption(_ runID: RunID, at finishedAt: Date, isReadOnly: Bool) async throws -> Bool {
        do {
            guard let decoded = try decodedRecovery(for: runID) else { return false }
            let row = decoded.row
            guard !decoded.itemAudit.isUnsafe else { return false }
            let transitions = decoded.payload?.transitions ?? decoded.fallback?.transitions
            let preservesTerminalOutcome = Self.hasTerminalAudit(row, transitions: transitions)
                || (row.finishedAt != nil
                    && RunLifecycleState(rawValue: row.stateRaw).map(Self.isTerminalState) == true)
            let route = Self.corruptionRoute(for: row, payload: decoded.payload, fallback: decoded.fallback)
            guard Self.allowsCorruptionClosure(
                row,
                payload: decoded.payload,
                fallback: decoded.fallback,
                route: route,
                isReadOnly: isReadOnly
            ) else { return false }
            if try repairTerminalRow(
                decoded,
                route: route,
                at: finishedAt
            ) {
                try modelContext.save()
                return true
            }
            guard !preservesTerminalOutcome else { return false }
            do {
                _ = try makeRecord(from: row)
                return false
            } catch is RunRecordPersistenceError {
                try recoverCorruptedRow(
                    decoded,
                    route: route,
                    at: finishedAt
                )
            }
            _ = try makeRecord(from: row)
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func decodedRecovery(for runID: RunID) throws -> DecodedRecovery? {
        let targetID = runID.rawValue
        var descriptor = FetchDescriptor<PersistedRunRecord>(
            predicate: #Predicate { $0.runID == targetID }
        )
        descriptor.fetchLimit = 1
        guard let row = try modelContext.fetch(descriptor).first else { return nil }
        guard (try? makeRecord(from: row)) == nil else { return nil }
        do {
            let decoded = try RunPayloadCodec.decodeForRecovery(from: row)
            let itemAudit = recoveryItemAudit(
                for: row,
                payload: decoded.payload,
                fallback: decoded.fallback
            )
            return DecodedRecovery(
                row: row,
                payload: decoded.payload,
                fallback: decoded.fallback,
                itemAudit: itemAudit
            )
        } catch RunRecordPersistenceError.unsupportedPayloadVersion {
            return nil
        }
    }

    private func recoveryScope(
        for persisted: PersistedRunRecord,
        configuration: RunConfig?
    ) -> ProcessingScopeSnapshot {
        if let scope = try? JSONDecoder().decode(ProcessingScopeSnapshot.self, from: persisted.scopeData) {
            return scope
        }
        let fallback = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: nil,
            createdAt: persisted.startedAt,
            reason: RunTrigger.recovery.rawValue
        )
        guard let configuration else { return fallback }
        return ProcessingScopeSnapshot(
            id: configuration.scopeID,
            createdAt: fallback.createdAt,
            source: fallback.source,
            normalizedTestArtists: fallback.normalizedTestArtists,
            matchingRule: fallback.matchingRule,
            knownTrackCount: fallback.knownTrackCount,
            fingerprint: fallback.fingerprint,
            reason: fallback.reason
        )
    }

    private func recoverCorruptedRow(
        _ decoded: DecodedRecovery,
        route: CorruptionRoute,
        at finishedAt: Date
    ) throws {
        let row = decoded.row
        let payload = decoded.payload
        let fallback = decoded.fallback
        let workItems = try WorkLedger(decoded.itemAudit.workItems).dismissingOpenWork().items
        let storedConfiguration = payload?.configuration ?? fallback?.configuration
        let scope = recoveryScope(for: row, configuration: storedConfiguration)
        var transitions = Self.recoveryTransitions(row, payload: payload, fallback: fallback)
        if Self.hasTerminalAudit(row, transitions: transitions) {
            transitions.removeLast()
        }
        guard !transitions.contains(where: { Self.isTerminalState($0.state) }) else {
            throw RunRecordPersistenceError.corruptedField(name: "transitions", runID: row.runID)
        }
        let auditTime = max(finishedAt, transitions.last?.timestamp ?? finishedAt)
        let intent = RunIntent(rawValue: row.intentRaw)
        let isWriteRecovery = route == .writeRecovery
        if isWriteRecovery, transitions.last?.state != .recovering {
            transitions.append(RunLifecycleTransition(state: .recovering, timestamp: auditTime))
        }
        transitions.append(RunLifecycleTransition(state: .cancelled, timestamp: auditTime))

        row.triggerRaw = RunTrigger(rawValue: row.triggerRaw)?.rawValue ?? RunTrigger.recovery.rawValue
        row.intentRaw = isWriteRecovery ? RunIntent.writeFixes.rawValue : (intent ?? .observeLibrary).rawValue
        row.stateRaw = RunLifecycleState.cancelled.rawValue
        row.scopeData = try JSONEncoder().encode(scope)
        let configuration = recoveryConfiguration(
            payload?.configuration ?? fallback?.configuration,
            scope: scope,
            runID: row.runID
        )
        row.writeAuthorityRaw = configuration?.writeAuthority.rawValue
        guard workItems.isEmpty || configuration != nil else {
            throw RunRecordPersistenceError.corruptedField(name: "configuration", runID: row.runID)
        }
        let payloadVersion = RunRecordPayload.version(for: configuration)
        let storedRecoveryID = payload?.recoveryID ?? fallback?.recoveryID
        let recoveryID = isWriteRecovery ? (storedRecoveryID ?? row.runID) : nil
        row.transitionsData = try JSONEncoder().encode(RunRecordPayload(
            version: payloadVersion,
            transitions: transitions,
            workItems: workItems,
            configuration: configuration,
            writeTarget: payload?.writeTarget ?? fallback?.writeTarget,
            recoveryID: recoveryID,
            writeSummary: payload?.writeSummary ?? fallback?.writeSummary
        ))
        row.failureMessage = Self.corruptedRecoveryMessage(
            existing: row.failureMessage,
            isWriteRecovery: isWriteRecovery
        )
        row.finishedAt = auditTime
        try deleteWorkItems(for: row.runID)
    }

    private func repairTerminalRow(
        _ decoded: DecodedRecovery,
        route: CorruptionRoute,
        at finishedAt: Date
    ) throws -> Bool {
        let row = decoded.row
        let payload = decoded.payload
        let fallback = decoded.fallback
        let workItems = decoded.itemAudit.workItems
        let storedData = row.transitionsData
        let storedFinish = row.finishedAt
        let storedWriteAuthority = row.writeAuthorityRaw
        let transitions = Self.recoveryTransitions(row, payload: payload, fallback: fallback)
        guard Self.hasTerminalAudit(row, transitions: transitions),
              let terminalTime = transitions.last?.timestamp
        else { return false }

        let configuration = payload?.configuration ?? fallback?.configuration
        row.writeAuthorityRaw = configuration?.writeAuthority.rawValue
        guard workItems.isEmpty || configuration != nil else {
            throw RunRecordPersistenceError.corruptedField(name: "configuration", runID: row.runID)
        }
        row.transitionsData = try JSONEncoder().encode(RunRecordPayload(
            version: RunRecordPayload.version(for: configuration),
            transitions: transitions,
            workItems: workItems,
            configuration: configuration,
            writeTarget: payload?.writeTarget ?? fallback?.writeTarget,
            recoveryID: payload?.recoveryID ?? fallback?.recoveryID,
            writeSummary: payload?.writeSummary ?? fallback?.writeSummary
        ))
        row.finishedAt = max(storedFinish ?? finishedAt, terminalTime)
        do {
            _ = try makeRecord(from: row, loadsStoredWorkItems: false)
        } catch is RunRecordPersistenceError {
            row.transitionsData = storedData
            row.finishedAt = storedFinish
            row.writeAuthorityRaw = storedWriteAuthority
            return false
        }
        try deleteWorkItems(for: row.runID)
        row.failureMessage = Self.corruptedRecoveryMessage(
            existing: row.failureMessage,
            isWriteRecovery: route == .writeRecovery
        )
        return true
    }

    private func recoveryConfiguration(
        _ configuration: RunConfig?,
        scope: ProcessingScopeSnapshot,
        runID: UUID
    ) -> RunConfig? {
        guard let configuration else { return nil }
        guard configuration.scopeID == scope.id else {
            log.error("Dropping mismatched run configuration for \(runID.uuidString, privacy: .public)")
            return nil
        }
        return configuration
    }
}
