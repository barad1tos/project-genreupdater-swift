import Foundation

enum CorruptionRoute {
    case writeRecovery
    case readOnlyClosure
    case attention
    case diagnostic
    case unsupported
}

extension RunRecordDataStore {
    static func validatePayload(
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
        if let writeAuthorityRaw = persisted.writeAuthorityRaw,
           writeAuthorityRaw != payload.configuration?.writeAuthority.rawValue {
            throw RunRecordPersistenceError.corruptedField(name: "writeAuthority", runID: persisted.runID)
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

    func decodeSyncSummary(from persisted: PersistedRunRecord) -> ActivitySyncSummary? {
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

    static func hasInvalidStop(_ transitions: [RunLifecycleTransition]) -> Bool {
        transitions.dropLast().enumerated().contains { offset, transition in
            if isTerminalState(transition.state) {
                return true
            }
            guard transition.state == .blocked else { return false }
            return offset != transitions.count - 2 || transitions.last?.state != .cancelled
        }
    }

    static func hasInvalidTimeline(_ transitions: [RunLifecycleTransition]) -> Bool {
        hasInvalidStop(transitions) || hasTimeReversal(transitions)
    }

    static func hasTimeReversal(_ transitions: [RunLifecycleTransition]) -> Bool {
        zip(transitions, transitions.dropFirst()).contains { current, next in
            next.timestamp < current.timestamp
        }
    }

    static func hasTerminalAudit(
        _ row: PersistedRunRecord,
        transitions: [RunLifecycleTransition]?
    ) -> Bool {
        transitions?.last?.state.rawValue == row.stateRaw
            && transitions?.last.map { isTerminalState($0.state) } == true
    }

    static func isTerminalRepairable(
        _ row: PersistedRunRecord,
        payload: RunRecordPayload?,
        fallback: RecoveryPayload?
    ) -> Bool {
        guard fallback?.isWriteRecoveryRequired != true,
              RunTrigger(rawValue: row.triggerRaw) != nil,
              let intent = RunIntent(rawValue: row.intentRaw),
              let scope = try? JSONDecoder().decode(ProcessingScopeSnapshot.self, from: row.scopeData)
        else { return false }
        var transitions = payload?.transitions ?? fallback?.transitions ?? []
        let hasStateMismatch = transitions.last?.state.rawValue != row.stateRaw
        guard intent != .writeFixes || !hasStateMismatch else { return false }
        if let payloadState = transitions.last?.state,
           hasStateMismatch,
           isTerminalState(payloadState) || payloadState.needsWriteRecovery {
            return false
        }
        if hasStateMismatch,
           let state = RunLifecycleState(rawValue: row.stateRaw),
           isTerminalState(state) {
            let timestamp = max(row.finishedAt ?? row.startedAt, transitions.last?.timestamp ?? row.startedAt)
            transitions.append(RunLifecycleTransition(state: state, timestamp: timestamp))
        }
        guard hasTerminalAudit(row, transitions: transitions),
              !hasInvalidStop(transitions)
        else { return false }
        if let payload {
            let requiresConfiguration = payload.version >= RunRecordPayload.configurationVersion
            guard requiresConfiguration == (payload.configuration != nil) else { return false }
        }
        let configuration = payload?.configuration ?? fallback?.configuration
        guard configuration?.scopeID == nil || configuration?.scopeID == scope.id else { return false }
        return intent == .writeFixes || writeEvidenceField(
            configuration: configuration,
            writeTarget: payload?.writeTarget ?? fallback?.writeTarget,
            recoveryID: payload?.recoveryID ?? fallback?.recoveryID,
            transitions: transitions,
            writeSummary: payload?.writeSummary ?? fallback?.writeSummary
        ) == nil
    }

    static func isTerminalState(_ state: RunLifecycleState) -> Bool {
        switch state {
        case .completed, .completedNoOp, .failed, .cancelled:
            true
        case .created, .queued, .syncingLibrary, .analyzingDelta, .planningFixes, .awaitingReview,
             .writing, .verifying, .reporting, .blocked, .recoverable, .recovering:
            false
        }
    }

    static func invalidLifecycleField(state: RunLifecycleState, finishedAt: Date?) -> String? {
        switch state {
        case .completed, .completedNoOp, .failed, .cancelled:
            finishedAt == nil ? "finishedAt" : nil
        case .created, .queued, .syncingLibrary, .analyzingDelta, .planningFixes, .awaitingReview,
             .writing, .verifying, .reporting, .blocked, .recoverable, .recovering:
            finishedAt == nil ? nil : "finishedAt"
        }
    }

    static func validateRecord(_ record: RunRecord) throws {
        guard !record.transitions.isEmpty else {
            throw RunRecordPersistenceError.invalidField(name: "transitions", runID: record.runID.rawValue)
        }
        guard !hasInvalidTimeline(record.transitions) else {
            throw RunRecordPersistenceError.invalidField(name: "transitions", runID: record.runID.rawValue)
        }
        if let field = invalidLifecycleField(state: record.state, finishedAt: record.finishedAt) {
            throw RunRecordPersistenceError.invalidField(name: field, runID: record.runID.rawValue)
        }
        if record.intent != .writeFixes,
           let field = writeEvidenceField(
               configuration: record.configuration,
               writeTarget: record.writeTarget,
               recoveryID: record.recoveryID,
               transitions: record.transitions,
               writeSummary: record.writeSummary
           ) {
            throw RunRecordPersistenceError.invalidField(name: field, runID: record.runID.rawValue)
        }
        guard record.workItems.isEmpty || record.configuration != nil else {
            throw RunRecordPersistenceError.invalidField(name: "configuration", runID: record.runID.rawValue)
        }
        guard !hasInvalidWorkAuthority(
            record.workItems,
            intent: record.intent,
            configuration: record.configuration
        ) else {
            throw RunRecordPersistenceError.invalidField(name: "workItems", runID: record.runID.rawValue)
        }
        guard let configuration = record.configuration else { return }
        guard configuration.scopeID == record.scope.id else {
            throw RunRecordPersistenceError.invalidField(
                name: "configuration.scopeID",
                runID: record.runID.rawValue
            )
        }
        guard (try? JSONEncoder().encode(configuration)) != nil else {
            throw RunRecordPersistenceError.invalidField(
                name: "configuration",
                runID: record.runID.rawValue
            )
        }
    }

    static func hasInvalidWorkAuthority(
        _ workItems: [RunWorkItem],
        intent: RunIntent,
        configuration: RunConfig?
    ) -> Bool {
        let hasWriteState = workItems.contains { item in
            switch item.state {
            case .attempting, .attempted, .outcome(.written):
                true
            case .prepared, .outcome:
                false
            }
        }
        return hasWriteState
            && (intent != .writeFixes || configuration?.writeAuthority != .reviewedPlan)
    }

    static func isBlocked(
        _ row: PersistedRunRecord,
        payload: RunRecordPayload?,
        fallback: RecoveryPayload?
    ) -> Bool {
        let transitions = payload?.transitions ?? fallback?.transitions ?? []
        return row.stateRaw == RunLifecycleState.blocked.rawValue
            || transitions.contains { $0.state == .blocked }
    }

    static func hasUnsafeItemAudit(
        _ row: PersistedRunRecord,
        payload: RunRecordPayload?,
        fallback: RecoveryPayload?
    ) -> Bool {
        if fallback?.hasMalformedItems == true {
            return true
        }
        let workItems = payload?.workItems ?? fallback?.workItems ?? []
        guard !workItems.isEmpty else { return false }
        guard let configuration = payload?.configuration ?? fallback?.configuration,
              let scope = try? JSONDecoder().decode(ProcessingScopeSnapshot.self, from: row.scopeData)
        else { return true }
        return configuration.scopeID != scope.id
    }

    static func writeEvidenceField(
        configuration: RunConfig?,
        writeTarget: FixPlanWriteTarget?,
        recoveryID: UUID?,
        transitions: [RunLifecycleTransition]?,
        writeSummary: RunWriteSummary?
    ) -> String? {
        if configuration?.writeAuthority == .reviewedPlan {
            return "configuration.writeAuthority"
        }
        if writeTarget != nil {
            return "writeTarget"
        }
        if recoveryID != nil {
            return "recoveryID"
        }
        if writeSummary != nil {
            return "writeSummary"
        }
        if transitions?.contains(where: { isWriteExclusive($0.state) }) == true {
            return "transitions"
        }
        return nil
    }

    static func isWriteExclusive(_ state: RunLifecycleState) -> Bool {
        switch state {
        case .writing, .verifying, .recoverable, .recovering:
            true
        case .created, .queued, .syncingLibrary, .analyzingDelta, .planningFixes, .awaitingReview,
             .reporting, .completed, .completedNoOp, .blocked, .failed, .cancelled:
            false
        }
    }

    static func changedHeaderField(from stored: RunRecord, to replacement: RunRecord) -> String? {
        if let field = identityChangeField(from: stored, to: replacement) {
            return field
        }
        if let field = itemChangeField(from: stored.workItems, to: replacement.workItems) {
            return field
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

    static func identityChangeField(from stored: RunRecord, to replacement: RunRecord) -> String? {
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
        return nil
    }

    static func itemChangeField(from stored: [RunWorkItem], to replacement: [RunWorkItem]) -> String? {
        guard stored.count == replacement.count else { return "workItems" }
        var replacements: [UUID: RunWorkItem] = [:]
        for item in replacement {
            guard replacements.updateValue(item, forKey: item.id) == nil else { return "workItems" }
        }
        for item in stored {
            guard let next = replacements[item.id] else { return "workItems" }
            if item == next {
                continue
            }
            guard item.state != next.state,
                  let advanced = try? item.transition(to: next.state, detail: next.detail),
                  advanced == next
            else { return "workItems" }
        }
        return nil
    }

    static func changedTerminalField(from stored: RunRecord, to replacement: RunRecord) -> String? {
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

    static func changedTransitionField(from stored: RunRecord, to replacement: RunRecord) -> String? {
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
}
