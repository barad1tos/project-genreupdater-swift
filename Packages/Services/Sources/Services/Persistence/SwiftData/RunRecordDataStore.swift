import Foundation
import OSLog
import SwiftData

@ModelActor
public actor RunRecordDataStore: RunRecordStore {
    private let log = Logger(subsystem: "com.genreupdater", category: "RunRecordStore")

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

    public func recoveryRecords() async throws -> RunReportPage {
        let descriptor = FetchDescriptor<PersistedRunRecord>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        return try makePage(from: modelContext.fetch(descriptor)) {
            $0.finishedAt == nil && RunIntent(rawValue: $0.intentRaw) == .writeFixes
        }
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
        try await closeCorruption(runID, at: finishedAt, isReadOnly: false)
    }

    public func closeReadOnlyCorruption(_ runID: RunID, at finishedAt: Date) async throws -> Bool {
        try await closeCorruption(runID, at: finishedAt, isReadOnly: true)
    }

    private func closeCorruption(_ runID: RunID, at finishedAt: Date, isReadOnly: Bool) async throws -> Bool {
        do {
            let targetID = runID.rawValue
            var descriptor = FetchDescriptor<PersistedRunRecord>(
                predicate: #Predicate { $0.runID == targetID }
            )
            descriptor.fetchLimit = 1
            guard let row = try modelContext.fetch(descriptor).first else { return false }
            guard (try? makeRecord(from: row)) == nil else { return false }
            let decoded: (payload: RunRecordPayload?, fallback: RecoveryPayload?)
            do {
                decoded = try RunPayloadCodec.decodeForRecovery(from: row)
            } catch RunRecordPersistenceError.unsupportedPayloadVersion {
                return false
            }
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
            let payload = decoded.payload
            let recoveryPayload = decoded.fallback
            if try repairTerminalRow(
                row,
                payload: payload,
                fallback: recoveryPayload,
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
                    row,
                    payload: payload,
                    fallback: recoveryPayload,
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
        var closableRunIDs: [RunID] = []
        var attentionRunIDs: [RunID] = []
        var unsupportedRunIDs: [RunID] = []
        var skippedCorruptedCount = 0
        for row in rows {
            let isIncluded = shouldInclude(row)
            do {
                let record = try makeRecord(from: row)
                if isIncluded {
                    records.append(record)
                }
            } catch let error as RunRecordPersistenceError {
                skippedCorruptedCount += 1
                let runID = RunID(rawValue: row.runID)
                corruptedRunIDs.append(runID)
                switch corruptionRoute(for: row) {
                case .writeRecovery:
                    recoveryRunIDs.append(runID)
                case .readOnlyClosure:
                    closableRunIDs.append(runID)
                case .attention:
                    attentionRunIDs.append(runID)
                case .diagnostic:
                    break
                case .unsupported:
                    unsupportedRunIDs.append(runID)
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
            recoveryRunIDs: recoveryRunIDs,
            closableRunIDs: closableRunIDs,
            attentionRunIDs: attentionRunIDs,
            unsupportedRunIDs: unsupportedRunIDs
        )
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

        let payload = try RunPayloadCodec.decode(from: persisted)
        try Self.validatePayload(payload, persisted: persisted, scope: scope, intent: intent)

        let syncSummary = decodeSyncSummary(from: persisted)

        return RunRecord(
            runID: RunID(rawValue: persisted.runID),
            requestID: RunRequestID(rawValue: persisted.requestID),
            trigger: trigger,
            intent: intent,
            scope: scope,
            configuration: payload.configuration,
            writeTarget: payload.writeTarget,
            recoveryID: payload.recoveryID,
            transitions: payload.transitions,
            workItems: payload.workItems,
            syncSummary: syncSummary,
            writeSummary: payload.writeSummary,
            failureMessage: persisted.failureMessage,
            startedAt: persisted.startedAt,
            finishedAt: persisted.finishedAt
        )
    }

    private static func validatePayload(
        _ payload: RunRecordPayload,
        persisted: PersistedRunRecord,
        scope: ProcessingScopeSnapshot,
        intent: RunIntent
    ) throws {
        // An empty list would otherwise decode as a fake `.created` record (see RunRecord.state).
        guard !payload.transitions.isEmpty else {
            throw RunRecordPersistenceError.corruptedField(name: "transitions", runID: persisted.runID)
        }
        guard payload.transitions.last?.state.rawValue == persisted.stateRaw else {
            throw RunRecordPersistenceError.corruptedField(name: "state", runID: persisted.runID)
        }
        guard !hasInvalidTimeline(payload.transitions) else {
            throw RunRecordPersistenceError.corruptedField(name: "transitions", runID: persisted.runID)
        }
        if let state = payload.transitions.last?.state,
           let field = invalidLifecycleField(state: state, finishedAt: persisted.finishedAt) {
            throw RunRecordPersistenceError.corruptedField(name: field, runID: persisted.runID)
        }
        let requiresConfiguration = payload.version >= RunRecordPayload.configurationVersion
        guard requiresConfiguration == (payload.configuration != nil) else {
            throw RunRecordPersistenceError.corruptedField(name: "configuration", runID: persisted.runID)
        }
        if let configuration = payload.configuration,
           configuration.scopeID != scope.id {
            throw RunRecordPersistenceError.corruptedField(name: "configuration.scopeID", runID: persisted.runID)
        }
        if intent != .writeFixes,
           let field = Self.writeEvidenceField(
               configuration: payload.configuration,
               writeTarget: payload.writeTarget,
               recoveryID: payload.recoveryID,
               transitions: payload.transitions,
               writeSummary: payload.writeSummary
           ) {
            throw RunRecordPersistenceError.corruptedField(name: field, runID: persisted.runID)
        }
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

    private func corruptionRoute(for row: PersistedRunRecord) -> CorruptionRoute {
        do {
            let decoded = try RunPayloadCodec.decodeForRecovery(from: row)
            return Self.corruptionRoute(for: row, payload: decoded.payload, fallback: decoded.fallback)
        } catch RunRecordPersistenceError.unsupportedPayloadVersion {
            return .unsupported
        } catch {
            return .writeRecovery
        }
    }

    private static func changedHeaderField(from stored: RunRecord, to replacement: RunRecord) -> String? {
        if stored.requestID != replacement.requestID {
            return "requestID"
        }
        if stored.trigger != replacement.trigger {
            return "trigger"
        }
        if stored.intent != replacement.intent {
            return "intent"
        }
        if stored.scope != replacement.scope {
            return "scope"
        }
        if stored.configuration != replacement.configuration {
            return "configuration"
        }
        if stored.writeTarget != replacement.writeTarget {
            return "writeTarget"
        }
        if let field = changedTerminalField(from: stored, to: replacement) {
            return field
        }
        if let recoveryID = stored.recoveryID, recoveryID != replacement.recoveryID {
            return "recoveryID"
        }
        if let field = changedTransitionField(from: stored, to: replacement) {
            return field
        }
        if stored.startedAt != replacement.startedAt {
            return "startedAt"
        }
        return nil
    }

    private static func changedTerminalField(from stored: RunRecord, to replacement: RunRecord) -> String? {
        guard stored.finishedAt != nil else { return nil }
        if stored.recoveryID != replacement.recoveryID {
            return "recoveryID"
        }
        if stored.syncSummary != replacement.syncSummary {
            return "syncSummary"
        }
        if stored.writeSummary != replacement.writeSummary {
            return "writeSummary"
        }
        if stored.workItems != replacement.workItems {
            return "workItems"
        }
        if stored.failureMessage != replacement.failureMessage {
            return "failureMessage"
        }
        return nil
    }

    private static func changedTransitionField(from stored: RunRecord, to replacement: RunRecord) -> String? {
        if !replacement.transitions.starts(with: stored.transitions) {
            return "transitions"
        }
        if stored.finishedAt != nil, replacement.transitions != stored.transitions {
            return "transitions"
        }
        if let finishedAt = stored.finishedAt, replacement.finishedAt != finishedAt {
            return "finishedAt"
        }
        return nil
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
        _ row: PersistedRunRecord,
        payload: RunRecordPayload?,
        fallback: RecoveryPayload?,
        route: CorruptionRoute,
        at finishedAt: Date
    ) throws {
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
        let workItems = payload?.workItems ?? fallback?.workItems ?? []
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
    }

    private func repairTerminalRow(
        _ row: PersistedRunRecord,
        payload: RunRecordPayload?,
        fallback: RecoveryPayload?,
        route: CorruptionRoute,
        at finishedAt: Date
    ) throws -> Bool {
        let storedData = row.transitionsData
        let storedFinish = row.finishedAt
        let transitions = Self.recoveryTransitions(row, payload: payload, fallback: fallback)
        guard Self.hasTerminalAudit(row, transitions: transitions),
              let terminalTime = transitions.last?.timestamp
        else { return false }

        let configuration = payload?.configuration ?? fallback?.configuration
        let workItems = payload?.workItems ?? fallback?.workItems ?? []
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
            _ = try makeRecord(from: row)
        } catch is RunRecordPersistenceError {
            row.transitionsData = storedData
            row.finishedAt = storedFinish
            return false
        }
        row.failureMessage = Self.corruptedRecoveryMessage(
            existing: row.failureMessage,
            isWriteRecovery: route == .writeRecovery
        )
        return true
    }

    private static func corruptionRoute(
        for row: PersistedRunRecord,
        payload: RunRecordPayload?,
        fallback: RecoveryPayload?
    ) -> CorruptionRoute {
        guard payload != nil || fallback != nil else { return opaqueRoute(for: row) }
        return decodedRoute(for: row, payload: payload, fallback: fallback)
    }

    private static func opaqueRoute(for row: PersistedRunRecord) -> CorruptionRoute {
        if RunIntent(rawValue: row.intentRaw) == .writeFixes {
            return .attention
        }
        let isTerminal = RunLifecycleState(rawValue: row.stateRaw).map(isTerminalState) == true
        return isTerminal ? .diagnostic : .attention
    }

    private static func decodedRoute(
        for row: PersistedRunRecord,
        payload: RunRecordPayload?,
        fallback: RecoveryPayload?
    ) -> CorruptionRoute {
        guard !hasUnsafeItemAudit(row, payload: payload, fallback: fallback) else {
            return .attention
        }
        guard RunIntent(rawValue: row.intentRaw) != nil,
              let state = RunLifecycleState(rawValue: row.stateRaw)
        else { return .writeRecovery }
        let transitions = payload?.transitions ?? fallback?.transitions
        let isMissingConfiguration = payload.map {
            $0.version >= RunRecordPayload.configurationVersion && $0.configuration == nil
        } ?? false
        let hasWriteRisk = requiresWriteRecovery(row, payload: payload, fallback: fallback)
        if let route = terminalRoute(
            for: row,
            state: state,
            payload: payload,
            fallback: fallback,
            hasWriteRisk: hasWriteRisk
        ) {
            return route
        }
        if isBlocked(row, payload: payload, fallback: fallback) {
            return .attention
        }
        if isMissingConfiguration || hasWriteRisk || isWriteExclusive(state) {
            return .writeRecovery
        }
        if isTerminalState(state), row.finishedAt == nil {
            return .readOnlyClosure
        }
        if let transitions, hasTimeReversal(transitions) {
            return .readOnlyClosure
        }
        return .readOnlyClosure
    }

    private static func terminalRoute(
        for row: PersistedRunRecord,
        state: RunLifecycleState,
        payload: RunRecordPayload?,
        fallback: RecoveryPayload?,
        hasWriteRisk: Bool
    ) -> CorruptionRoute? {
        let transitions = payload?.transitions ?? fallback?.transitions
        if transitions?.contains(where: { isTerminalState($0.state) }) == true {
            guard hasTerminalAudit(row, transitions: transitions) else {
                return hasWriteRisk ? .attention : .diagnostic
            }
            guard isTerminalRepairable(row, payload: payload, fallback: fallback) else {
                return hasWriteRisk ? .attention : .diagnostic
            }
            return row.finishedAt == nil && hasWriteRisk ? .writeRecovery : .readOnlyClosure
        }
        if isTerminalState(state), row.finishedAt != nil {
            guard isTerminalRepairable(row, payload: payload, fallback: fallback) else {
                return hasWriteRisk ? .attention : .diagnostic
            }
            return .readOnlyClosure
        }
        return nil
    }

    private static func allowsCorruptionClosure(
        _ row: PersistedRunRecord,
        payload: RunRecordPayload?,
        fallback: RecoveryPayload?,
        route: CorruptionRoute,
        isReadOnly: Bool
    ) -> Bool {
        guard payload != nil || fallback != nil else { return false }
        guard !hasUnsafeItemAudit(row, payload: payload, fallback: fallback) else { return false }
        if isReadOnly {
            return route == .readOnlyClosure
                || (route == .attention && isReadOnlyAttention(row, payload: payload, fallback: fallback))
        }
        let transitions = payload?.transitions ?? fallback?.transitions
        return route == .writeRecovery
            && (hasTerminalAudit(row, transitions: transitions)
                || !isBlocked(row, payload: payload, fallback: fallback))
    }

    private func isPrunable(_ row: PersistedRunRecord) -> Bool {
        if (try? makeRecord(from: row)) != nil {
            return true
        }
        guard let state = RunLifecycleState(rawValue: row.stateRaw),
              Self.isTerminalState(state)
        else { return false }
        let route = corruptionRoute(for: row)
        guard route == .readOnlyClosure || route == .diagnostic,
              let decoded = try? RunPayloadCodec.decodeForRecovery(from: row)
        else { return false }
        guard decoded.payload != nil || decoded.fallback != nil else { return false }
        return !Self.requiresWriteRecovery(row, payload: decoded.payload, fallback: decoded.fallback)
    }

    private static func isReadOnlyAttention(
        _ row: PersistedRunRecord,
        payload: RunRecordPayload?,
        fallback: RecoveryPayload?
    ) -> Bool {
        guard fallback?.isWriteRecoveryRequired != true else { return false }
        let transitions = recoveryTransitions(row, payload: payload, fallback: fallback)
        if hasTerminalAudit(row, transitions: transitions) {
            return false
        }
        return !hasInvalidTimeline(transitions)
            && !transitions.contains(where: { isTerminalState($0.state) })
            && !requiresWriteRecovery(row, payload: payload, fallback: fallback)
    }

    private static func recoveryTransitions(
        _ row: PersistedRunRecord,
        payload: RunRecordPayload?,
        fallback: RecoveryPayload?
    ) -> [RunLifecycleTransition] {
        var previousTimestamp = row.startedAt
        var transitions = (payload?.transitions ?? fallback?.transitions ?? []).map { transition in
            let timestamp = max(previousTimestamp, transition.timestamp)
            previousTimestamp = timestamp
            return RunLifecycleTransition(state: transition.state, timestamp: timestamp)
        }
        if transitions.isEmpty {
            transitions.append(RunLifecycleTransition(state: .created, timestamp: row.startedAt))
        }
        if let state = RunLifecycleState(rawValue: row.stateRaw),
           transitions.last?.state != state,
           !(isTerminalState(state) && row.finishedAt == nil) {
            let headerTime = max(row.finishedAt ?? row.startedAt, transitions.last?.timestamp ?? row.startedAt)
            transitions.append(RunLifecycleTransition(
                state: state,
                timestamp: headerTime
            ))
        }
        return transitions
    }

    private static func requiresWriteRecovery(
        _ row: PersistedRunRecord,
        payload: RunRecordPayload?,
        fallback: RecoveryPayload?
    ) -> Bool {
        fallback?.isWriteRecoveryRequired == true
            || RunIntent(rawValue: row.intentRaw) == .writeFixes
            || writeEvidenceField(
                configuration: payload?.configuration ?? fallback?.configuration,
                writeTarget: payload?.writeTarget ?? fallback?.writeTarget,
                recoveryID: payload?.recoveryID ?? fallback?.recoveryID,
                transitions: payload?.transitions ?? fallback?.transitions,
                writeSummary: payload?.writeSummary ?? fallback?.writeSummary
            ) != nil
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

    private func saveOrRollback() throws {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private static func corruptedRecoveryMessage(existing: String?, isWriteRecovery: Bool) -> String {
        let closure = if isWriteRecovery {
            "Recovery closed after Music.app verification; the stored run payload was corrupted."
        } else {
            "Corrupted run closed; no Music.app write recovery was required."
        }
        return existing.map { "\($0) \(closure)" } ?? closure
    }
}
