import Core
import Foundation
import Services

/// The batch work stashed between submit and the orchestrator's runner
/// firing (D3): tracks and context stay screen-side; only options and
/// count travel in the run request.
struct PendingBatchExecution {
    let tracksByIndex: [Track]
    let contextTracks: [Track]
    let preflightOutcome: PendingEntryOutcome
    let options: UpdateOptions
}

enum WorkflowBatchError: LocalizedError {
    case noPendingExecution

    var errorDescription: String? {
        "The batch runner fired without a pending execution"
    }
}

extension WorkflowViewModel {
    // MARK: - Batch Processing (Full Library mode)

    func startBatchProcessing(
        tracks: [Track],
        contextTracks: [Track]? = nil,
        preflightOutcome: PendingEntryOutcome = PendingEntryOutcome()
    ) {
        let tracksByIndex = Self.sortedForBatchProcessing(tracks)
        guard !tracksByIndex.isEmpty else {
            phase = .error("No tracks in the current scope")
            progress = nil
            currentTrackID = nil
            return
        }
        guard let submitBatchRun else {
            phase = .error("Run service is unavailable")
            progress = nil
            currentTrackID = nil
            return
        }

        phase = .scanning
        processedCount = 0
        failedCount = 0
        batchNoOpEntries = []
        batchFailedTrackIDs = []
        batchFailureDescriptions = []
        trackStatuses = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, TrackProcessingStatus.queued) })
        currentTrackID = nil

        let options = UpdateOptions(
            updateGenre: updateGenre,
            updateYear: updateYear,
            repairExistingGenreMismatches: mode == .fullLibrary,
            forceYearLookup: forceYearLookup,
            cleanTrackNames: cleanTrackNames,
            cleanAlbumNames: cleanAlbumNames,
            minConfidence: confidencePercentage,
            autoAccept: true
        )
        pendingBatchExecution = PendingBatchExecution(
            tracksByIndex: tracksByIndex,
            contextTracks: contextTracks ?? tracksByIndex,
            preflightOutcome: preflightOutcome,
            options: options
        )

        processingTask = Task {
            do {
                let submission = try await submitBatchRun(
                    BatchRunInput(options: options, trackCount: tracksByIndex.count)
                )
                applyBatchSubmissionResult(submission)
            } catch {
                pendingBatchExecution = nil
                phase = .error(error.localizedDescription)
                progress = nil
            }
        }
    }

    /// The orchestrator's runner target (D3): executes the stashed work
    /// through the same coordinator path with the same screen progress;
    /// every failure rethrows AFTER applying its screen state so the run
    /// record stays honest.
    func performBatchRunWork(input _: BatchRunInput, runID _: RunID) async throws -> BatchUpdateResult {
        guard let execution = pendingBatchExecution else {
            throw WorkflowBatchError.noPendingExecution
        }
        pendingBatchExecution = nil
        let tracksByIndex = execution.tracksByIndex
        let progressHandler = makeBatchProgressHandler(tracksByIndex: tracksByIndex)
        do {
            await invalidateAlbumYearCacheIfNeeded()

            let context = await batchContext(for: tracksByIndex, contextTracks: execution.contextTracks)
            let operation = makeBatchTrackOperation(
                updateCoordinator: updateCoordinator,
                options: execution.options,
                albumTracksByTrackID: context.albums,
                artistTracksByTrackID: context.artists
            )

            let entries = try await batchProcessor.process(
                tracks: tracksByIndex,
                operation: operation,
                progressHandler: progressHandler
            )

            await finishBatchProcessing(
                preflightOutcome: execution.preflightOutcome,
                batchEntries: entries,
                tracks: tracksByIndex
            )
            return result ?? BatchUpdateResult(
                entries: entries,
                noOpEntries: batchNoOpEntries,
                failedTrackIDs: batchFailedTrackIDs,
                errorDescriptions: batchFailureDescriptions
            )
        } catch is CancellationError {
            finishCancelledBatch(preflightOutcome: execution.preflightOutcome)
            phase = .configure
            progress = nil
            throw CancellationError()
        } catch let error as AppleScriptOutcomeError {
            // The orchestrator routes this to recovery and holds through
            // the SAME processor; the screen keeps only the failure phase
            // (a second view-model hold would double-lock the processor).
            retainPreflightOutcome(execution.preflightOutcome)
            phase = .error(error.localizedDescription)
            progress = nil
            throw error
        } catch let batchError as BatchProcessorError {
            if case let .cancelled(liveProcessedCount, liveTotalCount) = batchError {
                finishCancelledBatch(
                    preflightOutcome: execution.preflightOutcome,
                    liveProcessedCount: liveProcessedCount,
                    liveTotalCount: liveTotalCount
                )
                phase = .configure
                progress = nil
                throw CancellationError()
            }
            handleBatchProcessingError(batchError, preflightOutcome: execution.preflightOutcome)
            throw batchError
        } catch {
            retainPreflightOutcome(execution.preflightOutcome)
            phase = .error(error.localizedDescription)
            progress = nil
            throw error
        }
    }

    private func applyBatchSubmissionResult(_ submission: RunSubmissionResult) {
        switch submission {
        case .queued, .alreadyCovered:
            // The runner fires when the active run finishes; the batch
            // progress handler takes the screen over from there.
            progress = ProgressUpdate(
                phase: .fetching,
                current: 0,
                total: totalCount,
                message: "Waiting for the active run to finish"
            )
        case .recoveryRequired:
            pendingBatchExecution = nil
            phase = .error("Recovery needs attention before this run can start")
            progress = nil
        case .completed, .completedNoOp, .failed, .cancelled, .recoverable:
            // Terminal screen state was applied inside performBatchRunWork
            // (or its error taxonomy) before the orchestrator returned.
            break
        }
    }

    private func finishBatchProcessing(
        preflightOutcome: PendingEntryOutcome,
        batchEntries: [ChangeLogEntry],
        tracks: [Track]
    ) async {
        finalizeBatchStatuses(for: tracks)
        restorePreflightStatuses(preflightOutcome)

        let allEntries = preflightOutcome.completed + batchEntries
        completedEntries = allEntries
        let currentFailures = failedTracks
        result = BatchUpdateResult(
            entries: allEntries,
            noOpEntries: batchNoOpEntries,
            failedTrackIDs: preflightOutcome.failedTrackIDs + batchFailedTrackIDs,
            errorDescriptions: preflightOutcome.errorDescriptions + batchFailureDescriptions
        )
        failedCount = currentFailures.count
        processedCount = preflightOutcome.processedCount + tracks.count
        totalCount = max(totalCount, processedCount)
        if currentFailures.isEmpty {
            await updateIncrementalRunTimestamp?()
        }
        currentTrackID = nil
        recoveryHoldID = nil
        phase = .done
        progress = nil
    }

    func clearRecoveryHold() async {
        guard let recoveryHoldID else { return }
        do {
            try await clearRecovery(recoveryHoldID)
            self.recoveryHoldID = nil
            guard await !stopForRecoveryHold() else { return }
            reset()
        } catch {
            phase = .error(error.localizedDescription)
            progress = nil
        }
    }

    private func invalidateAlbumYearCacheIfNeeded() async {
        guard updateYear, forceYearLookup else { return }
        await invalidateAlbumYearCache?()
    }

    private func batchContext(
        for tracks: [Track],
        contextTracks: [Track]
    ) async -> (albums: [String: [Track]], artists: [String: [Track]]) {
        let albumTracksByTrackID = await updateCoordinator.albumContextTracksByTrackID(for: contextTracks)
        let artistGroups = Self.groupTracksByArtist(contextTracks)
        return (
            albums: Dictionary(uniqueKeysWithValues: tracks.map {
                ($0.id, albumTracksByTrackID[$0.id] ?? [])
            }),
            artists: Dictionary(uniqueKeysWithValues: tracks.map {
                ($0.id, artistGroups[Self.artistKey(for: $0)] ?? [])
            })
        )
    }

    private func makeBatchTrackOperation(
        updateCoordinator: UpdateCoordinator,
        options: UpdateOptions,
        albumTracksByTrackID: [String: [Track]],
        artistTracksByTrackID: [String: [Track]]
    ) -> @Sendable (Track) async throws -> [ChangeLogEntry] {
        { [weak self] track in
            do {
                let batchResult = try await updateCoordinator.updateTracks(
                    [track],
                    options: options,
                    albumTracksProvider: Self.albumTracksProvider(albumTracksByTrackID),
                    artistTracksProvider: Self.artistTracksProvider(artistTracksByTrackID),
                    progressHandler: Self.ignoreNestedTrackProgress
                )
                await self?.recordBatchTrackFailures(
                    track: track,
                    failedTrackIDs: batchResult.failedTrackIDs,
                    errorDescriptions: batchResult.errorDescriptions
                )
                await self?.appendBatchNoOpEntries(batchResult.noOpEntries)
                return batchResult.entries
            } catch let updateError as UpdateCoordinatorError {
                await self?.recordBatchTrackFailure(track: track, error: updateError)
                throw updateError
            } catch {
                await self?.recordBatchTrackFailure(track: track, error: error)
                throw error
            }
        }
    }

    private func appendBatchNoOpEntries(_ entries: [ChangeLogEntry]) {
        batchNoOpEntries.append(contentsOf: entries)
    }

    private func recordBatchTrackFailures(
        track: Track,
        failedTrackIDs: [String],
        errorDescriptions: [String]
    ) {
        let pairs = Self.failurePairs(
            defaultTrackID: track.id,
            failedTrackIDs: failedTrackIDs,
            errorDescriptions: errorDescriptions
        )
        guard !pairs.isEmpty else { return }
        batchFailedTrackIDs.append(contentsOf: pairs.map(\.trackID))
        batchFailureDescriptions.append(contentsOf: pairs.map(\.message))
        markBatchTrackFailed(track, message: pairs.map(\.message).joined(separator: "\n"))
    }

    private func recordBatchTrackFailure(track: Track, error: Error) {
        if case let UpdateCoordinatorError.allTracksFailed(_, errorDescriptions) = error {
            recordBatchTrackFailures(
                track: track,
                failedTrackIDs: Array(repeating: track.id, count: max(1, errorDescriptions.count)),
                errorDescriptions: errorDescriptions.isEmpty ? [error.localizedDescription] : errorDescriptions
            )
            return
        }

        recordBatchTrackFailures(
            track: track,
            failedTrackIDs: [track.id],
            errorDescriptions: [error.localizedDescription]
        )
    }

    nonisolated private static func failurePairs(
        defaultTrackID: String,
        failedTrackIDs: [String],
        errorDescriptions: [String]
    ) -> [(trackID: String, message: String)] {
        let failureCount = max(failedTrackIDs.count, errorDescriptions.count)
        guard failureCount > 0 else { return [] }
        return (0 ..< failureCount).map { index in
            (
                trackID: failedTrackIDs[safe: index] ?? defaultTrackID,
                message: errorDescriptions[safe: index] ?? "No failure details were captured for this run."
            )
        }
    }

    private func markBatchTrackFailed(_ track: Track, message: String) {
        trackStatuses[track.id] = .failed(message)
        failedCount = failedTracks.count
    }

    private func handleBatchProcessingError(
        _ error: BatchProcessorError,
        preflightOutcome: PendingEntryOutcome
    ) {
        switch error {
        case let .cancelled(liveProcessedCount, liveTotalCount):
            finishCancelledBatch(
                preflightOutcome: preflightOutcome,
                liveProcessedCount: liveProcessedCount,
                liveTotalCount: liveTotalCount
            )
            phase = .configure
            progress = nil
        case let .recoveryRequired(batchID):
            recoveryHoldID = batchID
            retainPreflightOutcome(preflightOutcome)
            handleBatchError(error)
        case .featureNotAvailable, .alreadyRunning, .notRunning:
            retainPreflightOutcome(preflightOutcome)
            handleBatchError(error)
        }
    }

    private func finishCancelledBatch(
        preflightOutcome: PendingEntryOutcome,
        liveProcessedCount: Int? = nil,
        liveTotalCount: Int? = nil
    ) {
        trackStatuses = [:]
        failedCount = 0
        batchNoOpEntries = []
        batchFailedTrackIDs = []
        batchFailureDescriptions = []
        if preflightOutcome.isEmpty {
            completedEntries = []
            result = nil
            currentTrackID = nil
        } else {
            retainPreflightOutcome(preflightOutcome)
        }

        if let liveProcessedCount {
            processedCount = preflightOutcome.processedCount + liveProcessedCount
        }
        if let liveTotalCount {
            totalCount = max(totalCount, preflightOutcome.processedCount + liveTotalCount)
        }
    }

    private func retainPreflightOutcome(_ outcome: PendingEntryOutcome) {
        guard !outcome.isEmpty else {
            currentTrackID = nil
            return
        }

        restorePreflightStatuses(outcome)
        completedEntries = outcome.completed
        result = BatchUpdateResult(
            entries: outcome.completed,
            failedTrackIDs: outcome.failedTrackIDs,
            errorDescriptions: outcome.errorDescriptions
        )
        processedCount = outcome.processedCount
        failedCount = outcome.failedTrackIDs.count
        totalCount = max(totalCount, outcome.processedCount)
        currentTrackID = nil
    }

    func restorePreflightStatuses(_ outcome: PendingEntryOutcome) {
        let successfulTrackIDs = Set(outcome.successfulTrackIDs + outcome.completed.map(\.trackID))
        for trackID in successfulTrackIDs {
            if case .failed = trackStatuses[trackID] {
                continue
            }
            trackStatuses[trackID] = .done
        }
        restorePreflightFailures(outcome)
    }

    private func restorePreflightFailures(_ outcome: PendingEntryOutcome) {
        guard !outcome.failedTrackIDs.isEmpty else { return }

        let fallbackMessage = outcome.errorDescriptions.first ?? "Pending verification failed"
        for (index, trackID) in outcome.failedTrackIDs.enumerated() {
            let message = if outcome.errorDescriptions.indices.contains(index) {
                outcome.errorDescriptions[index]
            } else {
                fallbackMessage
            }
            trackStatuses[trackID] = .failed(message)
        }
    }

    nonisolated private static func albumTracksProvider(
        _ albumTracksByTrackID: [String: [Track]]
    ) -> @Sendable (Track) -> [Track] {
        { track in
            albumTracksByTrackID[track.id] ?? []
        }
    }

    nonisolated private static func artistTracksProvider(
        _ artistTracksByTrackID: [String: [Track]]
    ) -> @Sendable (Track) -> [Track] {
        { track in
            artistTracksByTrackID[track.id] ?? []
        }
    }

    nonisolated private static func ignoreNestedTrackProgress(_: ProgressUpdate) {
        // BatchProcessor emits the user-visible progress for full-library runs.
    }

    private func makeBatchProgressHandler(tracksByIndex: [Track]) -> @Sendable (ProgressUpdate) -> Void {
        { [weak self] update in
            Task { @MainActor in
                self?.handleBatchProgress(update, tracksByIndex: tracksByIndex)
            }
        }
    }

    private func handleBatchProgress(_ update: ProgressUpdate, tracksByIndex: [Track]) {
        progress = update
        processedCount = update.current

        guard update.current > 0 else {
            currentTrackID = nil
            return
        }

        if tracksByIndex.indices.contains(update.current - 1) {
            let currentTrack = tracksByIndex[update.current - 1]
            currentTrackID = currentTrack.id
            if !isFailedTrack(currentTrack.id) {
                trackStatuses[currentTrack.id] = .writing
            }

            // Mark previous track as done if it was still writing
            if update.current > 1 {
                let previousTrack = tracksByIndex[update.current - 2]
                if case .writing = trackStatuses[previousTrack.id] {
                    trackStatuses[previousTrack.id] = .done
                }
            }
        }

        if update.phase == .complete, let lastTrack = tracksByIndex.last {
            markWritingTrackDone(lastTrack)
        }
    }

    private func markWritingTrackDone(_ track: Track) {
        if case .writing = trackStatuses[track.id] {
            trackStatuses[track.id] = .done
        }
    }

    private func isFailedTrack(_ trackID: String) -> Bool {
        if case .failed = trackStatuses[trackID] {
            return true
        }
        return false
    }

    private func finalizeBatchStatuses(for tracks: [Track]) {
        for track in tracks {
            if case .queued = trackStatuses[track.id] {
                trackStatuses[track.id] = .skipped
            }
        }
    }
}
