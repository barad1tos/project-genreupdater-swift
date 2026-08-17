import Core
import Foundation

struct BatchFinalization {
    let currentTracksByID: [String: Track]
    let appliedIndexes: Set<Int>
    let noOpIndexes: Set<Int>
    let preflightFailures: [Int: UpdateCoordinatorError]
}

extension UpdateCoordinator {
    func finishBatchWrite(
        _ preparedWrites: [PreparedWrite],
        batch: BatchFinalization,
        failedTrackIDs: inout [String],
        errorDescriptions: inout [String],
        checkpoint: WorkCheckpointSink?
    ) async throws -> AppliedChangeEntries {
        // Outcomes are fully determined before finalization, so checkpoint them
        // first: a finalization failure must not erase N verified writes.
        do {
            try await checkpointBatch(preparedWrites, batch: batch, sink: checkpoint)
        } catch {
            // The batch was physically dispatched: caches must not keep serving
            // pre-write values even when the checkpoint cannot persist.
            await invalidateBatchCaches(preparedWrites)
            throw error
        }
        return try await appliedChangeEntries(
            for: preparedWrites,
            batch: batch,
            failedTrackIDs: &failedTrackIDs,
            errorDescriptions: &errorDescriptions
        )
    }

    func partialBatchFailure(
        _ preparedWrites: [PreparedWrite],
        batch: BatchFinalization,
        attemptedIndexes: Set<Int>,
        error: AppleScriptBatchVerificationError,
        checkpoint: WorkCheckpointSink?
    ) async throws -> any Error {
        let confirmedIndexes = batch.appliedIndexes.union(batch.noOpIndexes)
        let outcome = Self.partialBatchOutcome(
            applied: batch.appliedIndexes.count,
            attempted: attemptedIndexes.count,
            error: error
        )
        // Confirmed outcomes checkpoint before finalization, and the outcome
        // error outranks a finalization failure: it keeps recovery engaged for
        // the unverified writes (no ScriptCompletion exists here — the batch
        // script already returned).
        do {
            try await checkpointBatch(
                preparedWrites,
                batch: batch,
                sink: checkpoint,
                indexes: confirmedIndexes,
                preserving: outcome
            )
        } catch {
            await invalidateBatchCaches(preparedWrites)
            throw error
        }
        var reportedOutcome = outcome
        let recordedEffects = await recordBatchEffects(
            preparedWrites,
            batch: batch,
            indexes: confirmedIndexes
        )
        if let error = recordedEffects.error {
            log.error("""
            Batch finalization failed after checkpointing \(confirmedIndexes.count, privacy: .public) confirmed \
            outcomes with \(String(describing: type(of: error)), privacy: .public): \
            \(error.localizedDescription, privacy: .private)
            """)
            reportedOutcome = AppleScriptOutcomeError(
                scriptName: "batch_update_tracks",
                reason: outcome.reason +
                    "; write finalization failed for \(batch.appliedIndexes.count) applied writes"
            )
        }
        for index in attemptedIndexes.subtracting(batch.appliedIndexes).sorted() {
            await invalidateCaches(for: preparedWrites[index].change)
        }
        guard !recordedEffects.trackIDs.isEmpty else { return reportedOutcome }
        return PartialWriteError(
            appliedTrackIDs: recordedEffects.trackIDs,
            underlyingError: reportedOutcome
        )
    }

    private func invalidateBatchCaches(_ preparedWrites: [PreparedWrite]) async {
        for write in preparedWrites {
            await invalidateCaches(for: write.change)
        }
    }

    private func checkpointBatch(
        _ preparedWrites: [PreparedWrite],
        batch: BatchFinalization,
        sink: WorkCheckpointSink?,
        indexes: Set<Int>? = nil
    ) async throws {
        guard let sink else { return }
        var outcomes: [UUID: WorkOutcome] = [:]
        for (index, write) in preparedWrites.enumerated() {
            if let indexes, !indexes.contains(index) {
                continue
            }
            outcomes[write.change.id] = Self.batchWorkOutcome(at: index, write: write, batch: batch)
        }
        if !outcomes.isEmpty {
            try await sink(.afterVerification(outcomes))
        }
    }

    private func checkpointBatch(
        _ preparedWrites: [PreparedWrite],
        batch: BatchFinalization,
        sink: WorkCheckpointSink?,
        indexes: Set<Int>,
        preserving outcome: AppleScriptOutcomeError
    ) async throws {
        do {
            try await checkpointBatch(preparedWrites, batch: batch, sink: sink, indexes: indexes)
        } catch let WorkCheckpointError.store(failure) {
            throw WorkCheckpointError.store(failure.withOutcome(outcome))
        }
    }

    private func appliedChangeEntries(
        for preparedWrites: [PreparedWrite],
        batch: BatchFinalization,
        failedTrackIDs: inout [String],
        errorDescriptions: inout [String]
    ) async throws -> AppliedChangeEntries {
        var entries: [ChangeLogEntry] = []
        var noOpEntries: [ChangeLogEntry] = []
        var firstFinalizationError: (any Error)?
        for (writeIndex, preparedWrite) in preparedWrites.enumerated() {
            switch Self.batchWorkOutcome(at: writeIndex, write: preparedWrite, batch: batch) {
            case .noFixNeeded:
                await invalidateCaches(for: preparedWrite.change)
                noOpEntries.append(Self.noOpLogEntry(preparedWrite.change))
                continue
            case .failed:
                if let error = batch.preflightFailures[writeIndex] {
                    try recordWorkflowWriteFailure(
                        error,
                        isReviewedChange: true,
                        trackID: preparedWrite.change.track.id,
                        failedTrackIDs: &failedTrackIDs,
                        errorDescriptions: &errorDescriptions
                    )
                } else {
                    await recordUnverifiedBatchWrite(
                        preparedWrite,
                        failedTrackIDs: &failedTrackIDs,
                        errorDescriptions: &errorDescriptions
                    )
                }
                continue
            case .written:
                do {
                    let entry = try await recordAppliedChange(preparedWrite.change)
                    entries.append(entry)
                } catch {
                    firstFinalizationError = firstFinalizationError ?? error
                }
            case .fixProposed, .needsReview, .skipped, .deferred, .dismissed:
                assertionFailure("Unexpected terminal batch work outcome")
            }
        }
        if let firstFinalizationError {
            guard !entries.isEmpty else { throw firstFinalizationError }
            throw PartialWriteError(
                appliedTrackIDs: Set(entries.map(\.trackID)),
                underlyingError: firstFinalizationError
            )
        }
        return (entries, noOpEntries)
    }

    private static func batchWorkOutcome(
        at index: Int,
        write: PreparedWrite,
        batch: BatchFinalization
    ) -> WorkOutcome {
        if batch.noOpIndexes.contains(index) {
            return .noFixNeeded
        }
        guard batch.appliedIndexes.contains(index) else {
            return .failed
        }
        guard let priorTrack = batch.currentTracksByID[write.trackID] else {
            return .written
        }
        let wasAlreadyApplied = write.updates.allSatisfy { update in
            guard let property = AppleScriptTrackProperty(rawValue: update.property) else { return false }
            return property.comparisonValue(value(forAppleScriptProperty: update.property, in: priorTrack))
                == property.comparisonValue(update.value)
        }
        return wasAlreadyApplied ? .noFixNeeded : .written
    }

    private func recordUnverifiedBatchWrite(
        _ preparedWrite: PreparedWrite,
        failedTrackIDs: inout [String],
        errorDescriptions: inout [String]
    ) async {
        await invalidateCaches(for: preparedWrite.change)
        recordUnexpectedFailure(
            trackID: preparedWrite.change.track.id,
            error: UpdateCoordinatorError.writeFailed(
                trackID: preparedWrite.change.track.id,
                property: preparedWrite.property,
                reason: "Batch write could not be verified after the batch script ran"
            ),
            failedTrackIDs: &failedTrackIDs,
            errorDescriptions: &errorDescriptions
        )
    }

    private static func partialBatchOutcome(
        applied: Int,
        attempted: Int,
        error: AppleScriptBatchVerificationError
    ) -> AppleScriptOutcomeError {
        let reason = "verification covered only \(applied) of \(attempted) writes after dispatch: " +
            error.localizedDescription
        return AppleScriptOutcomeError(scriptName: "batch_update_tracks", reason: reason)
    }

    private func recordBatchEffects(
        _ preparedWrites: [PreparedWrite],
        batch: BatchFinalization,
        indexes: Set<Int>
    ) async -> (trackIDs: Set<String>, error: (any Error)?) {
        var trackIDs: Set<String> = []
        var firstFinalizationError: (any Error)?
        for index in indexes.sorted() {
            let write = preparedWrites[index]
            switch Self.batchWorkOutcome(at: index, write: write, batch: batch) {
            case .written:
                do {
                    let entry = try await recordAppliedChange(write.change)
                    trackIDs.insert(entry.trackID)
                } catch {
                    firstFinalizationError = firstFinalizationError ?? error
                }
            case .noFixNeeded:
                await invalidateCaches(for: write.change)
            case .failed, .fixProposed, .needsReview, .skipped, .deferred, .dismissed:
                assertionFailure("Unexpected unconfirmed batch work outcome")
            }
        }
        return (trackIDs, firstFinalizationError)
    }
}
