import Core
import Foundation

private struct ReviewedBatchPreflight {
    let writeIndexes: Set<Int>
    let noOpIndexes: Set<Int>
    let failures: [Int: UpdateCoordinatorError]
}

extension UpdateCoordinator {
    func applyChangesAsBatchIfPossible(
        _ changes: [ProposedChange],
        isReviewedChange: Bool = true,
        failedTrackIDs: inout [String],
        errorDescriptions: inout [String],
        checkpoint: WorkCheckpointSink? = nil
    ) async throws -> AppliedChangeEntries? {
        guard runtimeConfiguration.areBatchUpdatesEnabled,
              changes.count > 1,
              changes.count <= runtimeConfiguration.maxBatchUpdateSize
        else {
            return nil
        }

        guard let preparedWrites = try await prepareBatchWrites(
            changes,
            isReviewedChange: isReviewedChange
        ) else {
            return nil
        }

        let batchOutcome: BatchFinalization
        do {
            guard let verifiedBatchOutcome = try await performVerifiedBatchWrite(
                preparedWrites,
                isReviewedChange: isReviewedChange,
                checkpoint: checkpoint
            ) else {
                return nil
            }
            batchOutcome = verifiedBatchOutcome
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PartialWriteError {
            throw error
        } catch let error as WorkCheckpointError {
            throw error
        } catch let error as AppleScriptOutcomeError {
            throw error
        } catch let error as UpdateCoordinatorError {
            throw error
        } catch {
            log.warning("""
            Batch AppleScript write failed; falling back to single writes: \
            \(error.localizedDescription, privacy: .private)
            """)
            return nil
        }

        return try await finishBatchWrite(
            preparedWrites,
            batch: batchOutcome,
            failedTrackIDs: &failedTrackIDs,
            errorDescriptions: &errorDescriptions,
            checkpoint: checkpoint
        )
    }

    private func prepareBatchWrites(
        _ changes: [ProposedChange],
        isReviewedChange: Bool
    ) async throws -> [PreparedWrite]? {
        var preparedWrites: [PreparedWrite] = []
        for change in changes {
            do {
                let outcome = try await prepareWrite(
                    for: change,
                    isReviewedChange: isReviewedChange
                )
                guard case let .write(preparedWrite) = outcome else {
                    return nil
                }
                preparedWrites.append(preparedWrite)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log.warning("""
                Batch write preparation failed; falling back to single writes: \
                \(error.localizedDescription, privacy: .private)
                """)
                return nil
            }
        }
        return preparedWrites
    }

    private func performVerifiedBatchWrite(
        _ preparedWrites: [PreparedWrite],
        isReviewedChange: Bool,
        checkpoint: WorkCheckpointSink?
    ) async throws -> BatchFinalization? {
        guard let currentTracksByID = try await fetchBatchWriteTracks(preparedWrites) else {
            log.warning(
                "Batch AppleScript write preflight could not fetch current tracks; falling back to single writes"
            )
            return nil
        }

        let preflight = try reviewedBatchPreflight(
            preparedWrites,
            currentTracksByID: currentTracksByID,
            isReviewedChange: isReviewedChange
        )
        guard !preflight.writeIndexes.isEmpty else {
            return BatchFinalization(
                currentTracksByID: currentTracksByID,
                appliedIndexes: [],
                noOpIndexes: preflight.noOpIndexes,
                preflightFailures: preflight.failures
            )
        }

        return try await executeBatchWrite(
            preparedWrites,
            currentTracksByID: currentTracksByID,
            preflight: preflight,
            checkpoint: checkpoint
        )
    }

    private func executeBatchWrite(
        _ preparedWrites: [PreparedWrite],
        currentTracksByID: [String: Track],
        preflight: ReviewedBatchPreflight,
        checkpoint: WorkCheckpointSink?
    ) async throws -> BatchFinalization {
        let writesToApply = preflight.writeIndexes.sorted().map { preparedWrites[$0] }
        let itemIDs = writesToApply.map(\.change.id)
        try await checkpoint?(.beforeAttempt(itemIDs))
        let attemptState = WriteAttemptState()
        do {
            try await dispatchBatchWrite(
                writesToApply,
                attemptState: attemptState,
                preparedWrites: preparedWrites,
                attemptedIndexes: preflight.writeIndexes,
                checkpoint: checkpoint
            )
        } catch let error as AppleScriptBatchVerificationError {
            return try await verifyBatchAfterFailure(
                preparedWrites,
                currentTracksByID: currentTracksByID,
                preflight: preflight,
                error: error,
                checkpoint: checkpoint
            )
        }

        return BatchFinalization(
            currentTracksByID: currentTracksByID,
            appliedIndexes: preflight.writeIndexes,
            noOpIndexes: preflight.noOpIndexes,
            preflightFailures: preflight.failures
        )
    }

    private func dispatchBatchWrite(
        _ writesToApply: [PreparedWrite],
        attemptState: WriteAttemptState,
        preparedWrites: [PreparedWrite],
        attemptedIndexes: Set<Int>,
        checkpoint: WorkCheckpointSink?
    ) async throws {
        let itemIDs = writesToApply.map(\.change.id)
        do {
            try await scriptBridge.batchUpdateTracks(
                writesToApply.map { write in
                    TrackPropertyUpdate(
                        trackID: write.trackID,
                        property: write.property,
                        value: write.value
                    )
                },
                onAttempt: {
                    attemptState.markAttempted()
                    try await checkpoint?(.afterAttempt(itemIDs))
                }
            )
        } catch is CancellationError {
            await invalidateAttemptedBatch(
                preparedWrites,
                indexes: attemptedIndexes,
                attemptState: attemptState
            )
            throw CancellationError()
        } catch let failure as WriteAttemptFailure {
            await invalidateAttemptedBatch(
                preparedWrites,
                indexes: attemptedIndexes,
                attemptState: attemptState
            )
            throw reportAttemptFailure(failure)
        } catch let error as WorkCheckpointError {
            await invalidateAttemptedBatch(
                preparedWrites,
                indexes: attemptedIndexes,
                attemptState: attemptState
            )
            throw error
        } catch let error as AppleScriptOutcomeError {
            await invalidateBatchCaches(preparedWrites, indexes: attemptedIndexes)
            throw error
        } catch let error as AppleScriptBatchVerificationError {
            throw error
        } catch let error where attemptState.hasAttempted {
            await invalidateBatchCaches(preparedWrites, indexes: attemptedIndexes)
            throw AppleScriptOutcomeError(
                scriptName: "batch_update_tracks",
                reason: "returned an error after dispatch: \(error.localizedDescription)"
            )
        } catch {
            throw error
        }
    }

    private func invalidateAttemptedBatch(
        _ preparedWrites: [PreparedWrite],
        indexes: Set<Int>,
        attemptState: WriteAttemptState
    ) async {
        guard attemptState.hasAttempted else { return }
        await invalidateBatchCaches(preparedWrites, indexes: indexes)
    }

    private func reviewedBatchPreflight(
        _ preparedWrites: [PreparedWrite],
        currentTracksByID: [String: Track],
        isReviewedChange: Bool
    ) throws -> ReviewedBatchPreflight {
        for preparedWrite in preparedWrites {
            guard let currentTrack = currentTracksByID[preparedWrite.trackID] else { continue }
            try Self.validateMutationEligibility(
                for: currentTrack,
                requiresKnownStatus: true,
                errorTrackID: preparedWrite.change.track.id
            )
        }
        guard isReviewedChange else {
            return ReviewedBatchPreflight(
                writeIndexes: Set(preparedWrites.indices),
                noOpIndexes: [],
                failures: [:]
            )
        }

        var writeIndexes = Set<Int>()
        var noOpIndexes = Set<Int>()
        var failures: [Int: UpdateCoordinatorError] = [:]
        for (index, preparedWrite) in preparedWrites.enumerated() {
            guard let currentTrack = currentTracksByID[preparedWrite.trackID] else {
                continue
            }
            do {
                let shouldWrite = try shouldWrite(
                    preparedWrite.change,
                    to: currentTrack,
                    property: preparedWrite.property,
                    staleTrackID: preparedWrite.change.track.id
                )
                if shouldWrite {
                    writeIndexes.insert(index)
                } else {
                    noOpIndexes.insert(index)
                }
            } catch let error as UpdateCoordinatorError {
                guard case .reviewedChangeStale = error else { throw error }
                failures[index] = error
            }
        }
        return ReviewedBatchPreflight(
            writeIndexes: writeIndexes,
            noOpIndexes: noOpIndexes,
            failures: failures
        )
    }

    private func verifyBatchAfterFailure(
        _ preparedWrites: [PreparedWrite],
        currentTracksByID: [String: Track],
        preflight: ReviewedBatchPreflight,
        error: AppleScriptBatchVerificationError,
        checkpoint: WorkCheckpointSink?
    ) async throws -> BatchFinalization {
        do {
            guard let appliedIndexes = try await verifiedIndexes(
                preparedWrites,
                attemptedIndexes: preflight.writeIndexes
            ) else {
                await invalidateBatchCaches(preparedWrites, indexes: preflight.writeIndexes)
                throw AppleScriptOutcomeError(
                    scriptName: "batch_update_tracks",
                    reason: "could not verify metadata after dispatch: \(error.localizedDescription)"
                )
            }
            guard appliedIndexes == preflight.writeIndexes else {
                let batch = BatchFinalization(
                    currentTracksByID: currentTracksByID,
                    appliedIndexes: appliedIndexes,
                    noOpIndexes: preflight.noOpIndexes,
                    preflightFailures: preflight.failures
                )
                let outcome = try await partialBatchFailure(
                    preparedWrites,
                    batch: batch,
                    attemptedIndexes: preflight.writeIndexes,
                    error: error,
                    checkpoint: checkpoint
                )
                throw outcome
            }
            return BatchFinalization(
                currentTracksByID: currentTracksByID,
                appliedIndexes: appliedIndexes,
                noOpIndexes: preflight.noOpIndexes,
                preflightFailures: preflight.failures
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PartialWriteError {
            throw error
        } catch let error as WorkCheckpointError {
            throw error
        } catch let outcome as AppleScriptOutcomeError {
            throw outcome
        } catch {
            await invalidateBatchCaches(preparedWrites, indexes: preflight.writeIndexes)
            throw AppleScriptOutcomeError(
                scriptName: "batch_update_tracks",
                reason: "verification failed after dispatch: \(error.localizedDescription)"
            )
        }
    }

    private func invalidateBatchCaches(
        _ preparedWrites: [PreparedWrite],
        indexes: Set<Int>
    ) async {
        for index in indexes.sorted() {
            await invalidateCaches(for: preparedWrites[index].change)
        }
    }

    private func fetchBatchWriteTracks(_ preparedWrites: [PreparedWrite]) async throws -> [String: Track]? {
        let trackIDs = Array(Set(preparedWrites.map(\.trackID)))
        let fetchedTracks = try await scriptBridge.fetchTracksByIDs(
            trackIDs,
            batchSize: runtimeConfiguration.idsBatchSize,
            timeout: nil
        )
        let fetchedTracksByID = Dictionary(uniqueKeysWithValues: fetchedTracks.map { ($0.id, $0) })
        let hasAllTracks = trackIDs.allSatisfy { fetchedTracksByID[$0] != nil }
        return hasAllTracks ? fetchedTracksByID : nil
    }

    private func verifiedIndexes(
        _ preparedWrites: [PreparedWrite],
        attemptedIndexes: Set<Int>
    ) async throws -> Set<Int>? {
        guard let refreshedTracksByID = try await fetchBatchWriteTracks(preparedWrites) else {
            return nil
        }

        var appliedIndexes = Set<Int>()
        for (index, preparedWrite) in preparedWrites.enumerated() {
            guard attemptedIndexes.contains(index) else { continue }
            guard let refreshedTrack = refreshedTracksByID[preparedWrite.trackID] else {
                continue
            }
            let currentValue = Self.value(
                forAppleScriptProperty: preparedWrite.property,
                in: refreshedTrack
            )
            if currentValue == preparedWrite.value {
                appliedIndexes.insert(index)
            }
        }
        return appliedIndexes
    }
}
