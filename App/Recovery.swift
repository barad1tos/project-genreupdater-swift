import Core
import Foundation
import Services

private let recoveryLog = AppLogger.make(category: "recovery")

extension AppDependencies {
    func ensureRecoveryHold() async -> Bool {
        let activeLifecycle = await runOrchestrator?.activeLifecycle()
        let activeRunID = activeLifecycle?.runID
        let existingID: UUID? = if activeLifecycle?.intent == .writeFixes {
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
                    && $0.intent == .writeFixes
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
            await admitRecoveryHold(id: UUID())
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
        } else if await batchProcessor.recoveryHoldID() == id {
            try await batchProcessor.clearRecovery(batchID: id)
        }
        _ = await ensureRecoveryHold()
    }

    private func closeRecoveryRun(
        id: UUID,
        activeRunID: RunID?,
        allowsUnbound: Bool,
        at finishedAt: Date
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
            if let resolvedRunID = try await resolvedRecoveryRun(id: id, store: runRecordStore) {
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
            try await runRecordStore.upsert(record.closingRecovery(at: finishedAt))
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
        if let runID = recoveryRunIDs.first {
            guard try await store.closeCorruptedRun(runID, at: finishedAt) else {
                throw AppDependencyServiceError.recoveryUnavailable
            }
            return runID
        }
        if !unsupportedRunIDs.isEmpty {
            throw AppDependencyServiceError.recoveryUpdateRequired
        }
        if let runID = attentionRunIDs.first {
            guard try await store.closeReadOnlyCorruption(runID, at: finishedAt) else {
                throw AppDependencyServiceError.recoveryBlocked
            }
            return runID
        }
        return nil
    }

    private func resolvedRecoveryRun(id: UUID, store: any RunRecordStore) async throws -> RunID? {
        let history = try await store.reports(matching: RunReportQuery())
        return history.records.first { $0.recoveryID == id && $0.finishedAt != nil }?.runID
    }

    private func admitRecoveryHold(id: UUID) async {
        if let runOrchestrator {
            await runOrchestrator.restoreRecoveryHold(id: id)
        } else {
            _ = await batchProcessor?.beginRecoveryHold(id: id)
        }
    }

    private func restoreRecoveryHold(for candidate: RunRecord, preferredID: UUID?) async -> Bool {
        guard candidate.intent == .writeFixes,
              candidate.state.needsWriteRecovery
        else { return false }
        guard let runRecordStore else { return true }

        let requestedID = candidate.recoveryID ?? preferredID ?? UUID()
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
