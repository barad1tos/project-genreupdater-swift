import Core
import Foundation
import Services

private let recoveryLog = AppLogger.make(category: "recovery")

extension AppDependencies {
    func ensureRecoveryHold() async -> Bool {
        let hasHold = await discoverAndAdmitRecoveryHold()
        // Admission changes the orchestrator's hold fact — chrome's
        // source — without any lifecycle broadcast.
        await refreshChromeProjection()
        return hasHold
    }

    private func discoverAndAdmitRecoveryHold() async -> Bool {
        let activeLifecycle = await runOrchestrator?.activeLifecycle()
        let activeRunID = activeLifecycle?.runID
        let existingID: UUID? = if activeLifecycle?.intent.isMutating == true {
            nil
        } else {
            await batchProcessor?.recoveryHoldID()
        }
        guard let runRecordStore else { return existingID != nil }

        do {
            let page = try await runRecordStore.recoveryRecords()
            await closeClosableRuns(in: page, excluding: activeRunID)
            let candidates = page.records.filter {
                $0.finishedAt == nil
                    && $0.runID != activeRunID
                    && $0.intent.isMutating
                    && $0.state.needsWriteRecovery
            }

            if let existingID {
                await restoreExistingHold(id: existingID, candidates: candidates)
                // Preserve the active hold; clearing it re-runs discovery for the next persisted run.
                return true
            }

            if let corruptedRunID = page.recoveryRunIDs.first(where: { $0 != activeRunID }) {
                await admitRecoveryHold(id: corruptedRunID.rawValue)
                return true
            }
            if let unsupportedRunID = page.unsupportedRunIDs.first(where: { $0 != activeRunID }) {
                await admitRecoveryHold(id: unsupportedRunID.rawValue)
                return true
            }
            if let attentionRunID = page.attentionRunIDs.first(where: { $0 != activeRunID }) {
                await admitRecoveryHold(id: attentionRunID.rawValue)
                return true
            }
            for record in candidates where await restoreRecoveryHold(for: record, preferredID: nil) {
                return true
            }
            return false
        } catch {
            await admitRecoveryHold(id: SyntheticRecoveryHold.id)
            recoveryLog.error(
                "Failed to read recovery hold state: \(error.localizedDescription, privacy: .private)"
            )
            return true
        }
    }

    private func restoreExistingHold(id: UUID, candidates: [RunRecord]) async {
        let candidate = candidates.first(where: { $0.recoveryID == id })
            ?? candidates.first(where: { $0.recoveryID == nil })
        guard let candidate,
              await restoreRecoveryHold(for: candidate, preferredID: id)
        else {
            await admitRecoveryHold(id: id)
            return
        }
    }

    private func closeClosableRuns(in page: RunReportPage, excluding activeRunID: RunID?) async {
        guard let runRecordStore else { return }
        for runID in page.closableRunIDs where runID != activeRunID {
            do {
                guard try await runRecordStore.closeReadOnlyCorruption(runID, at: Date()) else {
                    recoveryLog.error("Could not close read-only corrupted run \(runID.rawValue, privacy: .public)")
                    continue
                }
            } catch {
                recoveryLog.error("""
                Failed to close read-only corrupted run \(runID.rawValue, privacy: .public): \
                \(error.localizedDescription, privacy: .private)
                """)
            }
        }
    }

    func clearRecoveryHold(id: UUID) async throws {
        if let task = recoveryClearTasks[id] {
            return try await task.value
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { throw AppDependencyServiceError.recoveryUnavailable }
            try await self.performRecoveryClear(id: id)
        }
        recoveryClearTasks[id] = task
        defer { recoveryClearTasks[id] = nil }
        try await task.value
        // A hold-only clearance broadcasts no lifecycle event; chrome must
        // re-derive its hold fact at this choke point for every caller.
        await refreshChromeProjection()
    }

    /// Dismisses selected recovery work and persists the still-open record;
    /// the hold is deliberately retained (ADR 0006 — dismissal resolves
    /// items, clearance resolves the run). Domain gates throw here and are
    /// mapped by the command layer, never routed through the run loop.
    func dismissRecoveryWork(
        id: UUID,
        itemIDs: [UUID],
        reason: String,
        isIndividual: Bool
    ) async throws {
        guard let runRecordStore else {
            throw AppDependencyServiceError.runRecordStoreUnavailable
        }
        let activeRunID = await runOrchestrator?.activeLifecycle()?.runID
        // The command surface carries run IDs (navigation currency) while
        // holds mint their own UUIDs, so match both keys like preflight does.
        let page = try await runRecordStore.recoveryRecords()
        guard let record = page.records.first(where: {
            ($0.runID.rawValue == id || $0.recoveryID == id) && $0.runID != activeRunID
        }) else {
            throw AppDependencyServiceError.recoveryUnavailable
        }
        let dismissedAt = Date()
        let updated: RunRecord
        if isIndividual {
            guard itemIDs.count == 1, let itemID = itemIDs.first else {
                throw AppDependencyServiceError.recoveryUnavailable
            }
            updated = try record.dismissingUncertainWork(id: itemID, reason: reason, at: dismissedAt)
        } else {
            updated = try record.dismissingWork(ids: Set(itemIDs), reason: reason, at: dismissedAt)
        }
        try await runRecordStore.upsert(updated)
    }

    func runRecoveryPreflight(runID: RunID) async -> RecoveryPreflightOutcome {
        guard let runRecordStore else {
            return .blocked(runID: runID, reason: .storeUnavailable)
        }

        do {
            let page = try await runRecordStore.recoveryRecords()
            if let record = page.records.first(where: {
                $0.runID == runID || $0.recoveryID == runID.rawValue
            }) {
                if record.requiresRecoveryObservation,
                   let recoveryAvailability,
                   case let .blocked(blocker) = await recoveryAvailability.status() {
                    return .blocked(runID: runID, reason: blocker)
                }
                return RecoveryPreflight.classify(record)
            }
            if page.recoveryRunIDs.contains(runID) {
                return .needsAttention(runID: runID, reason: .unresolvedState(.recoverable))
            }
            if page.unsupportedRunIDs.contains(runID) {
                return .needsAttention(runID: runID, reason: .unsupportedPayload)
            }
            if page.attentionRunIDs.contains(runID) {
                return .needsAttention(runID: runID, reason: .unresolvedState(.blocked))
            }
            return await RecoveryPreflightService(store: runRecordStore).run(for: runID)
        } catch {
            return .blocked(runID: runID, reason: .storeUnavailable)
        }
    }

    private func performRecoveryClear(id: UUID) async throws {
        guard let batchProcessor else {
            throw AppDependencyServiceError.recoveryUnavailable
        }
        let activeHoldID = await batchProcessor.recoveryHoldID()
        if let activeHoldID {
            guard activeHoldID == id else { throw AppDependencyServiceError.recoveryUnavailable }
        }

        let activeRunID = await runOrchestrator?.activeLifecycle()?.runID
        let finishedAt = Date()
        let targetRecord = try await selectRecoveryRecord(id: id, activeRunID: activeRunID)
        if let targetRecord, let runOrchestrator,
           await runOrchestrator.synchronizeRecovery(targetRecord) == false {
            throw AppDependencyServiceError.recoveryUnavailable
        }

        do {
            if let targetRecord {
                try await clearObservedRecovery(
                    id: id,
                    record: targetRecord,
                    activeRunID: activeRunID,
                    activeHoldID: activeHoldID,
                    at: finishedAt
                )
            } else {
                try await clearUnobservedRecovery(
                    id: id,
                    activeRunID: activeRunID,
                    activeHoldID: activeHoldID,
                    at: finishedAt
                )
            }
        } catch {
            // A failure after the in-memory hold cleared must re-admit the
            // hold immediately, or every retry rejects until the next write
            // attempt or relaunch rediscovers the still-open record.
            _ = await ensureRecoveryHold()
            throw error
        }
        _ = await ensureRecoveryHold()
    }

    /// Observation precedes every durable mutation: the close persists the
    /// observed outcomes, and resolving first means a failed close leaves an
    /// open record that ensureRecoveryHold re-offers on the next pass.
    private func clearObservedRecovery(
        id: UUID,
        record: RunRecord,
        activeRunID: RunID?,
        activeHoldID: UUID?,
        at finishedAt: Date
    ) async throws {
        guard let processor = batchProcessor else {
            throw AppDependencyServiceError.recoveryUnavailable
        }
        guard record.state != .blocked else {
            throw AppDependencyServiceError.recoveryBlocked
        }
        let observedOutcomes = try await observeOutcomes(for: record)
        try await repairFinalizationEvidence(record: record, observedOutcomes: observedOutcomes)
        if let runOrchestrator {
            guard await runOrchestrator.resolveRecovery(
                id: id,
                runID: record.runID,
                at: finishedAt,
                observedOutcomes: observedOutcomes
            ) == .resolved else {
                throw AppDependencyServiceError.recoveryVerificationFailed
            }
        }
        _ = try await closeRecoveryRun(
            id: id,
            activeRunID: activeRunID,
            allowsUnbound: activeHoldID != nil,
            at: finishedAt,
            observedOutcomes: observedOutcomes
        )
        if runOrchestrator == nil, await processor.recoveryHoldID() == id {
            try await processor.clearRecovery(batchID: id)
        }
    }

    /// Corrupted, unsupported, attention, and unbound targets keep the
    /// close-first order: their validation and attention routing live in the
    /// close path and no open record exists to observe.
    private func clearUnobservedRecovery(
        id: UUID,
        activeRunID: RunID?,
        activeHoldID: UUID?,
        at finishedAt: Date
    ) async throws {
        guard let processor = batchProcessor else {
            throw AppDependencyServiceError.recoveryUnavailable
        }
        let resolvedRunID = try await closeRecoveryRun(
            id: id,
            activeRunID: activeRunID,
            allowsUnbound: activeHoldID != nil,
            at: finishedAt
        )
        if let runOrchestrator {
            guard await runOrchestrator.resolveRecovery(
                id: id,
                runID: resolvedRunID,
                at: finishedAt
            ) == .resolved else {
                throw AppDependencyServiceError.recoveryUnavailable
            }
        } else if await processor.recoveryHoldID() == id {
            try await processor.clearRecovery(batchID: id)
        }
    }

    /// Rebuilds missing finalization evidence — durable change history, track
    /// metadata mirror, and processing state — for writes and verified no-ops.
    /// A repair failure aborts clearance and the hold is retained.
    private func repairFinalizationEvidence(
        record: RunRecord,
        observedOutcomes: [UUID: ObservedWorkOutcome]?
    ) async throws {
        guard let trackStore, let runRecordStore else {
            // Returning here reported a verified close over evidence that was
            // never rebuilt: the caller reads a normal return as repaired and
            // goes on to clear the hold. Fail closed so the hold is retained,
            // which is what this function's contract promises.
            recoveryLog.error("Recovery evidence repair blocked: track store unavailable")
            throw AppDependencyServiceError.recoveryUnavailable
        }
        let writtenItems = RecoveryEvidenceRepair.writtenItems(
            in: record.workItems,
            observed: observedOutcomes
        )
        let noOpItems = RecoveryEvidenceRepair.noOpItems(in: record.workItems)
        guard !writtenItems.isEmpty || !noOpItems.isEmpty else { return }
        let existing = try await loadRecoveryHistory(for: writtenItems)
        let writtenEntries = RecoveryEvidenceRepair.finalizationEntries(
            for: writtenItems,
            existing: existing,
            runID: record.runID.rawValue
        )
        let noOpEntries = try await makeNoOpFinalizationEntries(
            for: noOpItems,
            observedOutcomes: observedOutcomes,
            record: record,
            store: runRecordStore
        )
        guard writtenEntries.count == writtenItems.count,
              noOpEntries.count == noOpItems.count
        else {
            recoveryLog.error("Recovery evidence repair blocked: canonical write identity unavailable")
            throw AppDependencyServiceError.recoveryUnavailable
        }
        for entry in writtenEntries {
            _ = try await trackStore.commitAppliedChange(entry)
            await undoCoordinator?.recordCommittedChange(entry)
        }
        for entry in noOpEntries {
            _ = try await trackStore.commitObservedChange(entry)
        }
        let clearedRecord = try record.clearingRecoveryObservationIssues()
        if clearedRecord != record {
            try await runRecordStore.upsert(clearedRecord)
        }
    }

    private func loadRecoveryHistory(for writtenItems: [RunWorkItem]) async throws
        -> [ChangeLogEntry] {
        guard !writtenItems.isEmpty else { return [] }
        guard let undoCoordinator else {
            recoveryLog.error("Recovery evidence repair blocked: undo coordinator unavailable")
            throw AppDependencyServiceError.recoveryUnavailable
        }
        return try await undoCoordinator.loadDurableHistory()
    }

    private func makeNoOpFinalizationEntries(
        for items: [RunWorkItem],
        observedOutcomes: [UUID: ObservedWorkOutcome]?,
        record: RunRecord,
        store: any RunRecordStore
    ) async throws -> [ChangeLogEntry] {
        do {
            return try RecoveryEvidenceRepair.noOpFinalizationEntries(
                for: items,
                observed: observedOutcomes,
                runID: record.runID.rawValue
            )
        } catch let blocker as RecoveryObservationBlocker {
            do {
                try await store.upsert(record.recordingRecoveryObservationBlocker(blocker))
            } catch {
                recoveryLog.error("Recovery blocker could not be persisted for the affected work item")
                throw AppDependencyServiceError.recoveryUnavailable
            }
            throw AppDependencyServiceError.recoveryItemNeedsAttention(blocker)
        } catch let issue as RecoveryObservationIssue {
            throw AppDependencyServiceError.recoveryObservationNeedsAttention(issue)
        }
    }

    /// Finds the open recovery record bound to the hold without mutating it.
    /// Store failures propagate: clearance must not degrade to a blind close.
    private func selectRecoveryRecord(id: UUID, activeRunID: RunID?) async throws -> RunRecord? {
        guard let runRecordStore else {
            throw AppDependencyServiceError.runRecordStoreUnavailable
        }
        let page = try await runRecordStore.recoveryRecords()
        return page.records.first { $0.recoveryID == id && $0.runID != activeRunID }
    }

    /// Observes the physical Music.app state for the run's open work before
    /// clearance. Observation failures propagate so the hold is retained
    /// (ADR 0006: uncertainty cannot be cleared unchecked). Missing or failing
    /// observation infrastructure is surfaced as an actionable blocker.
    private func observeOutcomes(for record: RunRecord?) async throws -> [UUID: ObservedWorkOutcome]? {
        guard let record else { return nil }
        let hasOpenWork = record.workItems.contains { item in
            if case .outcome = item.state {
                return false
            }
            return true
        }
        guard hasOpenWork || record.requiresRecoveryObservation else { return nil }
        // Prepared-only records close locally. Write-uncertain work and legacy
        // no-ops without an authoritative effect must observe Music.app first.
        if record.requiresRecoveryObservation,
           let recoveryAvailability,
           case let .blocked(blocker) = await recoveryAvailability.status() {
            throw AppDependencyServiceError.recoveryObservationBlocked(blocker)
        }
        guard let recoveryVerifier else {
            recoveryLog.error("Recovery observation skipped: no observation client available")
            throw AppDependencyServiceError.recoveryObservationNeedsAttention(.observationUnavailable)
        }
        do {
            return try await RecoveryObservationService(verifier: recoveryVerifier)
                .observeOutcomes(for: record.workItems)
        } catch {
            recoveryLog.error("""
            Recovery observation failed for run \(record.runID.rawValue.uuidString, privacy: .public): \
            \(String(describing: type(of: error)), privacy: .public): \(error.localizedDescription, privacy: .private)
            """)
            throw AppDependencyServiceError.recoveryObservationNeedsAttention(.observationUnavailable)
        }
    }

    private func closeRecoveryRun(
        id: UUID,
        activeRunID: RunID?,
        allowsUnbound: Bool,
        at finishedAt: Date,
        observedOutcomes: [UUID: ObservedWorkOutcome]? = nil
    ) async throws -> RunID? {
        guard let runRecordStore else {
            throw AppDependencyServiceError.runRecordStoreUnavailable
        }
        let page = try await runRecordStore.recoveryRecords()
        let matchingRecords = page.records.filter { $0.recoveryID == id && $0.runID != activeRunID }
        let corruptedRunID = page.recoveryRunIDs.first { $0.rawValue == id && $0 != activeRunID }
        let attentionRunID = page.attentionRunIDs.first { $0.rawValue == id && $0 != activeRunID }
        let unsupportedRunID = page.unsupportedRunIDs.first { $0.rawValue == id && $0 != activeRunID }
        let targetCount = matchingRecords.count
            + (corruptedRunID == nil ? 0 : 1)
            + (attentionRunID == nil ? 0 : 1)
            + (unsupportedRunID == nil ? 0 : 1)
        if targetCount == 0 {
            if let resolvedRunID = try await runRecordStore.resolvedRecoveryRun(recoveryID: id) {
                return resolvedRunID
            }
            guard allowsUnbound else {
                throw AppDependencyServiceError.recoveryUnavailable
            }
            return try await closeUnboundRecovery(
                in: page,
                store: runRecordStore,
                activeRunID: activeRunID,
                at: finishedAt
            )
        }
        guard targetCount == 1 else {
            throw AppDependencyServiceError.recoveryUnavailable
        }

        if let record = matchingRecords.first {
            guard record.state != .blocked else {
                throw AppDependencyServiceError.recoveryBlocked
            }
            try await runRecordStore.upsert(
                record.closingRecovery(at: finishedAt, observedOutcomes: observedOutcomes)
            )
            return record.runID
        }
        return try await closeCorruptedTarget(
            recoveryRunID: corruptedRunID,
            attentionRunID: attentionRunID,
            unsupportedRunID: unsupportedRunID,
            store: runRecordStore,
            at: finishedAt
        )
    }

    private func closeCorruptedTarget(
        recoveryRunID: RunID?,
        attentionRunID: RunID?,
        unsupportedRunID: RunID?,
        store: any RunRecordStore,
        at finishedAt: Date
    ) async throws -> RunID {
        if unsupportedRunID != nil {
            throw AppDependencyServiceError.recoveryUpdateRequired
        }
        if let recoveryRunID {
            guard try await store.closeCorruptedRun(recoveryRunID, at: finishedAt) else {
                throw AppDependencyServiceError.recoveryUnavailable
            }
            return recoveryRunID
        }
        if let attentionRunID {
            guard try await store.closeReadOnlyCorruption(attentionRunID, at: finishedAt) else {
                throw AppDependencyServiceError.recoveryBlocked
            }
            return attentionRunID
        }
        throw AppDependencyServiceError.recoveryUnavailable
    }

    private func closeUnboundRecovery(
        in page: RunReportPage,
        store: any RunRecordStore,
        activeRunID: RunID?,
        at finishedAt: Date
    ) async throws -> RunID? {
        let records = page.records.filter { $0.recoveryID == nil && $0.runID != activeRunID }
        let recoveryRunIDs = page.recoveryRunIDs.filter { $0 != activeRunID }
        let attentionRunIDs = page.attentionRunIDs.filter { $0 != activeRunID }
        let unsupportedRunIDs = page.unsupportedRunIDs.filter { $0 != activeRunID }
        let targetCount = records.count + recoveryRunIDs.count + attentionRunIDs.count + unsupportedRunIDs.count
        guard targetCount <= 1 else {
            throw AppDependencyServiceError.recoveryUnavailable
        }
        if let record = records.first {
            guard record.state != .blocked else {
                throw AppDependencyServiceError.recoveryBlocked
            }
            try await store.upsert(record.closingRecovery(at: finishedAt))
            return record.runID
        }
        guard targetCount == 1 else { return nil }
        return try await closeCorruptedTarget(
            recoveryRunID: recoveryRunIDs.first,
            attentionRunID: attentionRunIDs.first,
            unsupportedRunID: unsupportedRunIDs.first,
            store: store,
            at: finishedAt
        )
    }

    private func admitRecoveryHold(id: UUID) async {
        if let runOrchestrator {
            await runOrchestrator.restoreRecoveryHold(id: id)
        } else {
            _ = await batchProcessor?.beginRecoveryHold(id: id)
        }
    }

    private func restoreRecoveryHold(for candidate: RunRecord, preferredID: UUID?) async -> Bool {
        guard candidate.intent.isMutating,
              candidate.state.needsWriteRecovery
        else { return false }
        guard let runRecordStore else { return true }

        // A fresh claim persists this ID onto the record, so it must stay
        // unique: the stable synthetic identity is for in-memory holds only
        // and must never flow in as the preferred claim identity either.
        let uniquePreferredID = preferredID == SyntheticRecoveryHold.id ? nil : preferredID
        let requestedID = candidate.recoveryID ?? uniquePreferredID ?? UUID()
        do {
            guard let recoveryID = try await runRecordStore.claimRecovery(
                for: candidate.runID,
                id: requestedID,
                at: Date()
            ) else { return false }
            if let restored = try await runRecordStore.record(for: candidate.runID) {
                if let runOrchestrator {
                    await runOrchestrator.restoreRecovery(restored)
                } else {
                    _ = await batchProcessor?.beginRecoveryHold(id: recoveryID)
                }
            } else {
                await admitRecoveryHold(id: recoveryID)
            }
            return true
        } catch {
            await admitRecoveryHold(id: requestedID)
            recoveryLog.error(
                "Failed to restore interrupted write record: \(error.localizedDescription, privacy: .private)"
            )
            return true
        }
    }
}
