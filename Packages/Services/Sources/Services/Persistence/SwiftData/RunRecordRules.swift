import Foundation

enum CorruptionRoute {
    case writeRecovery
    case readOnlyClosure
    case attention
    case diagnostic
    case unsupported
}

extension RunRecordDataStore {
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
}
