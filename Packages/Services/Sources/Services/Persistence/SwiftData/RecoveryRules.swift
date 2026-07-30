import Foundation

struct RecoveryItemAudit {
    let workItems: [RunWorkItem]
    let isUnsafe: Bool
}

extension RunRecordDataStore {
    func corruptionRoute(for row: PersistedRunRecord) -> CorruptionRoute {
        do {
            let decoded = try RunPayloadCodec.decodeForRecovery(from: row)
            let audit = recoveryItemAudit(
                for: row,
                payload: decoded.payload,
                fallback: decoded.fallback
            )
            guard !audit.isUnsafe else { return .attention }
            return Self.corruptionRoute(for: row, payload: decoded.payload, fallback: decoded.fallback)
        } catch RunRecordPersistenceError.unsupportedPayloadVersion {
            return .unsupported
        } catch {
            return .writeRecovery
        }
    }

    func recoveryItemAudit(
        for row: PersistedRunRecord,
        payload: RunRecordPayload?,
        fallback: RecoveryPayload?
    ) -> RecoveryItemAudit {
        let parentItems = payload?.workItems ?? fallback?.workItems ?? []
        guard !Self.hasUnsafeItemAudit(row, payload: payload, fallback: fallback) else {
            return RecoveryItemAudit(workItems: parentItems, isUnsafe: true)
        }

        do {
            let workItems = try loadWorkItems(for: row.runID, fallback: parentItems)
            let configuration = payload?.configuration ?? fallback?.configuration
            let intent = RunIntent(rawValue: row.intentRaw)
                ?? (configuration?.writeAuthority == .reviewedPlan ? .writeFixes : .observeLibrary)
            let hasInvalidAuthority = Self.hasInvalidWorkAuthority(
                workItems,
                intent: intent,
                configuration: configuration
            )
            return RecoveryItemAudit(
                workItems: workItems,
                isUnsafe: hasInvalidAuthority
                    || Self.hasOpenWork(finishedAt: row.finishedAt, workItems: workItems)
            )
        } catch {
            return RecoveryItemAudit(workItems: parentItems, isUnsafe: true)
        }
    }

    static func corruptionRoute(
        for row: PersistedRunRecord,
        payload: RunRecordPayload?,
        fallback: RecoveryPayload?
    ) -> CorruptionRoute {
        guard payload != nil || fallback != nil else { return opaqueRoute(for: row) }
        return decodedRoute(for: row, payload: payload, fallback: fallback)
    }

    static func opaqueRoute(for row: PersistedRunRecord) -> CorruptionRoute {
        if RunIntent(rawValue: row.intentRaw) == .writeFixes {
            return .attention
        }
        let isTerminal = RunLifecycleState(rawValue: row.stateRaw).map(isTerminalState) == true
        return isTerminal ? .diagnostic : .attention
    }

    static func decodedRoute(
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
        return .readOnlyClosure
    }

    static func terminalRoute(
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

    static func allowsCorruptionClosure(
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

    func isPrunable(_ row: PersistedRunRecord) -> Bool {
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

    static func isReadOnlyAttention(
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

    static func recoveryTransitions(
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

    static func requiresWriteRecovery(
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

    static func corruptedRecoveryMessage(existing: String?, isWriteRecovery: Bool) -> String {
        let closure = if isWriteRecovery {
            "Recovery closed after Music.app verification; the stored run payload was corrupted."
        } else {
            "Corrupted run closed; no Music.app write recovery was required."
        }
        return existing.map { "\($0) \(closure)" } ?? closure
    }
}
