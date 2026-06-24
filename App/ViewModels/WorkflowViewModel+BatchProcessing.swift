import Core
import Services

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

        phase = .scanning
        processedCount = 0
        failedCount = 0
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

        let progressHandler = makeBatchProgressHandler(tracksByIndex: tracksByIndex)

        processingTask = Task {
            do {
                await invalidateAlbumYearCacheIfNeeded()

                let context = await batchContext(for: tracksByIndex, contextTracks: contextTracks ?? tracksByIndex)
                let operation = makeBatchTrackOperation(
                    updateCoordinator: updateCoordinator,
                    options: options,
                    albumTracksByTrackID: context.albums,
                    artistTracksByTrackID: context.artists
                )

                let entries = try await batchProcessor.process(
                    tracks: tracksByIndex,
                    operation: operation,
                    progressHandler: progressHandler
                )

                await finishBatchProcessing(
                    preflightOutcome: preflightOutcome,
                    batchEntries: entries,
                    tracks: tracksByIndex
                )
            } catch is CancellationError {
                restorePreflightStatuses(preflightOutcome)
                currentTrackID = nil
                phase = .configure
                progress = nil
            } catch let batchError as BatchProcessorError {
                restorePreflightStatuses(preflightOutcome)
                currentTrackID = nil
                handleBatchError(batchError)
            } catch {
                restorePreflightStatuses(preflightOutcome)
                currentTrackID = nil
                phase = .error(error.localizedDescription)
                progress = nil
            }
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
            failedTrackIDs: currentFailures.map(\.id),
            errorDescriptions: currentFailures.map(\.error)
        )
        failedCount = currentFailures.count
        processedCount = preflightOutcome.processedCount + tracks.count
        totalCount = max(totalCount, processedCount)
        if currentFailures.isEmpty {
            await updateIncrementalRunTimestamp?()
        }
        currentTrackID = nil
        phase = .done
        progress = nil
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
                if let failureDescription = batchResult.errorDescriptions.first {
                    await self?.markBatchTrackFailed(track, message: failureDescription)
                }
                return batchResult.entries
            } catch {
                await self?.markBatchTrackFailed(track, message: error.localizedDescription)
                throw error
            }
        }
    }

    private func markBatchTrackFailed(_ track: Track, message: String) {
        trackStatuses[track.id] = .failed(message)
        failedCount = failedTracks.count
    }

    private func restorePreflightStatuses(_ outcome: PendingEntryOutcome) {
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
