import Core
import Foundation
import Services

/// The batch work stashed between submit and the orchestrator's runner
/// firing (D3): tracks and changes stay screen-side; only options and
/// count travel in the run request.
enum PendingBatchExecution {
    case fullLibrary(FullLibraryBatch)
    case applyAccepted(AcceptedChangesBatch)

    var options: UpdateOptions {
        switch self {
        case let .fullLibrary(batch): batch.options
        case let .applyAccepted(apply): apply.options
        }
    }

    var trackCount: Int {
        switch self {
        case let .fullLibrary(batch): batch.scope.tracks.count
        case let .applyAccepted(apply): apply.trackCount
        }
    }

    var admission: ProcessingAdmission {
        switch self {
        case let .fullLibrary(batch): batch.admission
        case let .applyAccepted(apply): apply.admission
        }
    }
}

struct FullLibraryBatch {
    let scope: UpdateTrackScope
    let contextTracks: [Track]
    let preflightOutcome: PendingEntryOutcome
    let options: UpdateOptions
    let admission: ProcessingAdmission
}

struct AcceptedChangesBatch {
    let accepted: [ProposedChange]
    let trackCount: Int
    let options: UpdateOptions
    let admission: ProcessingAdmission

    var requiredFeature: AppFeature? {
        accepted.lazy.compactMap(\.changeType.requiredWriteFeature).first
    }
}

enum WorkflowBatchError: LocalizedError {
    case staleExecution

    var errorDescription: String? {
        "The batch runner fired with work that no longer matches its run request"
    }
}

extension WorkflowViewModel {
    // MARK: - Batch Processing (Full Library mode)

    func startBatchProcessing(
        tracks: [Track],
        contextTracks: [Track]? = nil,
        preflightOutcome: PendingEntryOutcome = PendingEntryOutcome(),
        trackPasses: [String: UpdatePass] = [:]
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
        processingTask = Task {
            do {
                let admission = try await admitProcessing(tracksByIndex, .exactScope)
                pendingBatchExecution = .fullLibrary(FullLibraryBatch(
                    scope: UpdateTrackScope(tracks: tracksByIndex, trackPasses: trackPasses),
                    contextTracks: contextTracks ?? tracksByIndex,
                    preflightOutcome: preflightOutcome,
                    options: options,
                    admission: admission
                ))
                let submission = try await submitBatchRun(
                    BatchRunInput(
                        options: options,
                        trackCount: tracksByIndex.count,
                        admission: admission
                    )
                )
                applyBatchSubmissionResult(submission)
            } catch is CancellationError {
                pendingBatchExecution = nil
                phase = .configure
                progress = nil
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
    func performBatchRunWork(input: BatchRunInput, runID _: RunID) async throws -> BatchUpdateResult {
        guard let execution = pendingBatchExecution else {
            // The stash is cleared by cancel(): a queued trigger firing
            // after the user cancelled records an honest cancelled run.
            throw CancellationError()
        }
        guard input.options == execution.options,
              input.trackCount == execution.trackCount,
              input.admission == execution.admission
        else {
            // The record must never claim input A while the runner
            // executes stash B (divergence would be a silent lie). The
            // stash stays for its legitimate trigger — destroying it here
            // would park that later run on a foreign failure.
            throw WorkflowBatchError.staleExecution
        }
        pendingBatchExecution = nil
        switch execution {
        case let .fullLibrary(batch):
            return try await runFullLibraryBatch(batch)
        case let .applyAccepted(apply):
            return try await runAcceptedChanges(apply)
        }
    }

    private func runFullLibraryBatch(_ execution: FullLibraryBatch) async throws -> BatchUpdateResult {
        do {
            return try await executeBatchWork(execution)
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
                    batchTracks: execution.scope.tracks,
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

    private func executeBatchWork(_ execution: FullLibraryBatch) async throws -> BatchUpdateResult {
        let tracksByIndex = execution.scope.tracks
        let progressHandler = makeBatchProgressHandler(
            tracksByIndex: tracksByIndex,
            preflightOutcome: execution.preflightOutcome
        )
        await invalidateAlbumYearCacheIfNeeded()

        let context = await batchContext(for: tracksByIndex, contextTracks: execution.contextTracks)
        let operation = makeBatchTrackOperation(
            updateCoordinator: updateCoordinator,
            options: execution.options,
            scope: execution.scope,
            albumTracksByTrackID: context.albums,
            artistTracksByTrackID: context.artists
        )

        let entries = try await batchProcessor.process(
            tracks: tracksByIndex,
            validateWrite: { [validateProcessing, admission = execution.admission] in
                try await validateProcessing(admission, tracksByIndex, .exactScope)
            },
            operation: operation,
            progressHandler: progressHandler
        )

        await finishBatchProcessing(
            preflightOutcome: execution.preflightOutcome,
            batchEntries: entries,
            tracks: tracksByIndex
        )
        // The record reports THIS run's work only: preflight verification
        // writes happened before submit and stay merged into the screen
        // state (`result`), never the run record.
        return BatchUpdateResult(
            entries: entries,
            noOpEntries: batchNoOpEntries,
            failedTrackIDs: batchFailedTrackIDs,
            errorDescriptions: batchFailureDescriptions
        )
    }

    /// The apply-accepted runner section (PR C, Option A): the same
    /// recoverable write as before, but recovery belongs to the run —
    /// the orchestrator's finishRecoverableRun finds the processor hold
    /// performRecoverableWrite installed; this screen keeps the phase.
    private func runAcceptedChanges(_ apply: AcceptedChangesBatch) async throws -> BatchUpdateResult {
        let progressHandler = makeApplyProgressHandler()
        let coordinator = updateCoordinator
        do {
            let batchResult = try await batchProcessor.performRecoverableWrite(
                trackCount: Set(apply.accepted.map(\.track.id)).count,
                features: WriteFeatureRequirements(mutation: apply.requiredFeature),
                validateWrite: { [validateProcessing, admission = apply.admission] in
                    try await validateProcessing(
                        admission,
                        Self.uniqueTracks(apply.accepted.map(\.track)),
                        .subset
                    )
                },
                outcome: WriteOutcomeProjection(
                    appliedTrackIDs: { Set($0.entries.map(\.trackID)) },
                    partialTrackIDs: { _ in [] }
                ),
                operation: {
                    try await coordinator.applyAcceptedChanges(
                        apply.accepted,
                        progressHandler: progressHandler
                    )
                }
            )
            result = batchResult
            phase = .done
            progress = nil
            return batchResult
        } catch is CancellationError {
            phase = .configure
            progress = nil
            throw CancellationError()
        } catch {
            phase = .error(error.localizedDescription)
            progress = nil
            throw error
        }
    }

    func applyBatchSubmissionResult(_ submission: RunSubmissionResult) {
        switch submission {
        case .queued:
            // The runner fires when the active run finishes; the batch
            // progress handler takes the screen over from there. Cancel
            // stays live: it clears the stash, and the fired trigger
            // then records an honest cancelled run.
            progress = ProgressUpdate(
                phase: .fetching,
                current: 0,
                total: totalCount,
                message: "Waiting for the active run to finish"
            )
        case .alreadyCovered:
            // A covered submission never fires the runner — waiting for
            // it would park the screen forever.
            pendingBatchExecution = nil
            phase = .error("An equivalent run is already active; its results will cover this request")
            progress = nil
        case .recoveryRequired:
            // Defensive only: the submit-time recovery block guards the
            // write slot (writeFixes), so batches reach the processor's
            // own recoveryRequired error instead of this response.
            pendingBatchExecution = nil
            phase = .error("Recovery needs attention before this run can start")
            progress = nil
        case let .failed(lifecycle):
            applyPreRunnerTerminalIfNeeded(
                message: lifecycle.failureMessage ?? "Run failed before processing started"
            )
        case let .recoverable(_, reason):
            if pendingBatchExecution != nil {
                applyPreRunnerTerminalIfNeeded(message: reason)
            } else if case .done = phase {
                // The runner finished the screen, but finalization
                // installed a recovery hold — a done screen would hide
                // it until the next write attempt.
                phase = .error(reason)
                progress = nil
            }
        case .cancelled:
            if pendingBatchExecution != nil {
                pendingBatchExecution = nil
                phase = .configure
                progress = nil
            }
        case .completed, .completedNoOp:
            // Terminal screen state was applied inside performBatchRunWork
            // before the orchestrator returned.
            break
        }
    }

    /// A run can die BEFORE the runner consumes the stash (record store
    /// failure at preflight, an unavailable runner bridge): the remaining
    /// stash is the proof, and the screen must land on the failure
    /// instead of waiting for a runner that never fired.
    private func applyPreRunnerTerminalIfNeeded(message: String) {
        guard pendingBatchExecution != nil else { return }
        pendingBatchExecution = nil
        phase = .error(message)
        progress = nil
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
        processedCount = Self.combinedTrackCount(
            preflightOutcome: preflightOutcome,
            batchTracks: tracks,
            batchCount: tracks.count
        )
        totalCount = max(totalCount, processedCount)
        // Stricter than the Python original on purpose: a forced Python run
        // advances the mark even with per-track failures; holding the mark
        // back keeps failed tracks inside the next incremental window.
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
        let artistTracksByTrackID = await updateCoordinator.artistContextTracksByTrackID(for: contextTracks)
        return (
            albums: Dictionary(uniqueKeysWithValues: tracks.map {
                ($0.id, albumTracksByTrackID[$0.id] ?? [])
            }),
            artists: Dictionary(uniqueKeysWithValues: tracks.map {
                ($0.id, artistTracksByTrackID[$0.id] ?? [])
            })
        )
    }

    private func makeBatchTrackOperation(
        updateCoordinator: UpdateCoordinator,
        options: UpdateOptions,
        scope: UpdateTrackScope,
        albumTracksByTrackID: [String: [Track]],
        artistTracksByTrackID: [String: [Track]]
    ) -> @Sendable (Track) async throws -> [ChangeLogEntry] {
        let yearRunScope = YearRunScope()
        return { [weak self] track in
            do {
                let batchResult = try await updateCoordinator.updateTracks(
                    [track],
                    options: options,
                    pass: scope.pass(for: track),
                    albumTracksProvider: Self.albumTracksProvider(albumTracksByTrackID),
                    artistTracksProvider: Self.artistTracksProvider(artistTracksByTrackID),
                    yearRunScope: yearRunScope,
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
        batchTracks: [Track] = [],
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
            processedCount = Self.combinedTrackCount(
                preflightOutcome: preflightOutcome,
                batchTracks: batchTracks,
                batchCount: liveProcessedCount
            )
        }
        if let liveTotalCount {
            totalCount = max(
                totalCount,
                Self.combinedTrackCount(
                    preflightOutcome: preflightOutcome,
                    batchTracks: batchTracks,
                    batchCount: liveTotalCount
                )
            )
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

    private func makeBatchProgressHandler(
        tracksByIndex: [Track],
        preflightOutcome: PendingEntryOutcome
    ) -> @Sendable (ProgressUpdate) -> Void {
        { [weak self] update in
            Task { @MainActor in
                self?.handleBatchProgress(
                    update,
                    tracksByIndex: tracksByIndex,
                    preflightOutcome: preflightOutcome
                )
            }
        }
    }

    private func handleBatchProgress(
        _ update: ProgressUpdate,
        tracksByIndex: [Track],
        preflightOutcome: PendingEntryOutcome
    ) {
        let current = Self.combinedTrackCount(
            preflightOutcome: preflightOutcome,
            batchTracks: tracksByIndex,
            batchCount: update.current
        )
        let total = max(
            totalCount,
            Self.combinedTrackCount(
                preflightOutcome: preflightOutcome,
                batchTracks: tracksByIndex,
                batchCount: update.total
            )
        )
        progress = ProgressUpdate(phase: update.phase, current: current, total: total, message: update.message)
        processedCount = current

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

    nonisolated private static func combinedTrackCount(
        preflightOutcome: PendingEntryOutcome,
        batchTracks: [Track],
        batchCount: Int
    ) -> Int {
        let successfulTrackIDs = Set(preflightOutcome.successfulTrackIDs)
        let boundedCount = min(max(batchCount, 0), batchTracks.count)
        let newBatchTrackIDs = Set(batchTracks.prefix(boundedCount).map(\.id)).subtracting(successfulTrackIDs)
        return preflightOutcome.processedCount + newBatchTrackIDs.count
    }
}
