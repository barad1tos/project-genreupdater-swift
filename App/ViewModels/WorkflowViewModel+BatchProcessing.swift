import Core
import Services

extension WorkflowViewModel {
    // MARK: - Batch Processing (Full Library mode)

    func startBatchProcessing(tracks: [Track], contextTracks: [Track]? = nil) {
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
            forceYearLookup: forceYearLookup,
            cleanTrackNames: cleanTrackNames,
            cleanAlbumNames: cleanAlbumNames,
            minConfidence: confidencePercentage,
            autoAccept: true
        )

        let context = Self.batchContext(for: tracksByIndex, contextTracks: contextTracks ?? tracksByIndex)
        let operation = makeBatchTrackOperation(
            updateCoordinator: updateCoordinator,
            options: options,
            albumTracksByTrackID: context.albums,
            artistTracksByTrackID: context.artists
        )
        let progressHandler = makeBatchProgressHandler(tracksByIndex: tracksByIndex)

        processingTask = Task {
            do {
                let entries = try await batchProcessor.process(
                    tracks: tracksByIndex,
                    operation: operation,
                    progressHandler: progressHandler
                )

                finalizeBatchStatuses(for: tracksByIndex)
                completedEntries = entries
                if failedTracks.isEmpty {
                    await updateIncrementalRunTimestamp?()
                }
                currentTrackID = nil
                phase = .done
                progress = nil
            } catch is CancellationError {
                currentTrackID = nil
                phase = .configure
                progress = nil
            } catch let batchError as BatchProcessorError {
                currentTrackID = nil
                handleBatchError(batchError)
            } catch {
                currentTrackID = nil
                phase = .error(error.localizedDescription)
                progress = nil
            }
        }
    }

    private static func batchContext(
        for tracks: [Track],
        contextTracks: [Track]
    ) -> (albums: [String: [Track]], artists: [String: [Track]]) {
        let albumGroups = groupTracksByAlbum(contextTracks)
        let artistGroups = groupTracksByArtist(contextTracks)
        return (
            albums: Dictionary(uniqueKeysWithValues: tracks.map {
                ($0.id, albumGroups[albumKey(for: $0)] ?? [])
            }),
            artists: Dictionary(uniqueKeysWithValues: tracks.map {
                ($0.id, artistGroups[artistKey(for: $0)] ?? [])
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
