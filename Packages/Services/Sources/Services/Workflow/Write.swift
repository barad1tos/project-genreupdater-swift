import Core
import Foundation

private struct BatchWriteOutcome {
    let currentTracksByID: [String: Track]
    let appliedIndexes: Set<Int>
    let noOpIndexes: Set<Int>
    let preflightFailures: [Int: UpdateCoordinatorError]
}

private struct ReviewedBatchPreflight {
    let writeIndexes: Set<Int>
    let noOpIndexes: Set<Int>
    let failures: [Int: UpdateCoordinatorError]
}

extension UpdateCoordinator {
    typealias AppliedChangeEntries = (entries: [ChangeLogEntry], noOpEntries: [ChangeLogEntry])
    typealias AppliedChangeOutcome = (entry: ChangeLogEntry?, noOpEntry: ChangeLogEntry?)
    typealias UpdateTrackProviders = (album: @Sendable (Track) -> [Track], artist: @Sendable (Track) -> [Track])

    func consecutiveChangesForSameTrack(
        in changes: [ProposedChange],
        startingAt startIndex: Int
    ) -> [ProposedChange] {
        guard let firstChange = changes[safe: startIndex] else { return [] }
        var group: [ProposedChange] = []

        for change in changes[startIndex...] {
            guard change.track.id == firstChange.track.id else { break }
            group.append(change)
        }

        return group
    }

    func reviewedChangeGroup(
        in changes: [ProposedChange],
        startingAt startIndex: Int
    ) -> [ProposedChange] {
        let sameTrackGroup = consecutiveChangesForSameTrack(in: changes, startingAt: startIndex)
        if sameTrackGroup.count > 1 {
            return sameTrackGroup
        }

        guard runtimeConfiguration.areBatchUpdatesEnabled,
              runtimeConfiguration.maxBatchUpdateSize > 1,
              let firstChange = changes[safe: startIndex],
              Self.isAlbumYearBatchCandidate(firstChange)
        else {
            return sameTrackGroup
        }

        var group: [ProposedChange] = []
        for change in changes[startIndex...] {
            guard group.count < runtimeConfiguration.maxBatchUpdateSize,
                  Self.isAlbumYearBatchCandidate(change, matching: firstChange)
            else {
                break
            }
            group.append(change)
        }

        return group.count > 1 ? group : sameTrackGroup
    }

    func applyReviewedChangeGroup(
        _ changes: [ProposedChange],
        failedTrackIDs: inout [String],
        errorDescriptions: inout [String],
        checkpoint: WorkCheckpointSink? = nil
    ) async throws -> AppliedChangeEntries {
        if let applied = try await applyChangesAsBatchIfPossible(
            changes,
            isReviewedChange: true,
            failedTrackIDs: &failedTrackIDs,
            errorDescriptions: &errorDescriptions,
            checkpoint: checkpoint
        ) {
            return applied
        }

        var entries: [ChangeLogEntry] = []
        var noOpEntries: [ChangeLogEntry] = []
        for change in changes {
            do {
                let outcome = try await applyChangeOutcome(
                    change,
                    isReviewedChange: true,
                    checkpoint: checkpoint
                )
                if let entry = outcome.entry {
                    entries.append(entry)
                }
                if let noOpEntry = outcome.noOpEntry {
                    noOpEntries.append(noOpEntry)
                }
            } catch let error as WorkCheckpointError {
                throw error
            } catch let error as AppleScriptOutcomeError {
                throw error
            } catch {
                try recordWorkflowWriteFailure(
                    error,
                    isReviewedChange: true,
                    trackID: change.track.id,
                    failedTrackIDs: &failedTrackIDs,
                    errorDescriptions: &errorDescriptions
                )
            }
        }
        return (entries, noOpEntries)
    }

    func applyGeneratedAcceptedChanges(
        for track: Track,
        options: UpdateOptions,
        trackProviders: UpdateTrackProviders,
        failedTrackIDs: inout [String],
        errorDescriptions: inout [String]
    ) async throws -> AppliedChangeEntries {
        let albumTracksWithMutationMetadata = await availableTracksWithMutationMetadata(
            trackProviders.album(track)
        )
        let artistTracks = trackProviders.artist(track).filter(Self.isTrackAvailableForProcessing)
        let changes = try await updateTrack(
            track,
            albumTracks: albumTracksWithMutationMetadata,
            artistTracks: artistTracks,
            options: options,
            dryRun: true
        )

        let acceptedChanges = changes.filter(\.isAccepted)
        if let applied = try await applyChangesAsBatchIfPossible(
            acceptedChanges,
            isReviewedChange: false,
            failedTrackIDs: &failedTrackIDs,
            errorDescriptions: &errorDescriptions
        ) {
            return applied
        }

        var entries: [ChangeLogEntry] = []
        var noOpEntries: [ChangeLogEntry] = []
        for change in acceptedChanges {
            do {
                let outcome = try await applyChangeOutcome(change, isReviewedChange: false)
                if let entry = outcome.entry {
                    entries.append(entry)
                }
                if let noOpEntry = outcome.noOpEntry {
                    noOpEntries.append(noOpEntry)
                }
            } catch {
                try recordWorkflowWriteFailure(
                    error,
                    isReviewedChange: false,
                    trackID: change.track.id,
                    failedTrackIDs: &failedTrackIDs,
                    errorDescriptions: &errorDescriptions
                )
            }
        }
        return (entries, noOpEntries)
    }

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

        let batchOutcome: BatchWriteOutcome
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

        let entries = try await appliedChangeEntries(
            for: preparedWrites,
            batchOutcome: batchOutcome,
            failedTrackIDs: &failedTrackIDs,
            errorDescriptions: &errorDescriptions
        )
        try await checkpointBatch(preparedWrites, batch: batchOutcome, sink: checkpoint)
        return entries
    }

    private func checkpointBatch(
        _ preparedWrites: [PreparedWrite],
        batch: BatchWriteOutcome,
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

    private func appliedChangeEntries(
        for preparedWrites: [PreparedWrite],
        batchOutcome: BatchWriteOutcome,
        failedTrackIDs: inout [String],
        errorDescriptions: inout [String]
    ) async throws -> AppliedChangeEntries {
        var entries: [ChangeLogEntry] = []
        var noOpEntries: [ChangeLogEntry] = []
        var firstFinalizationError: (any Error)?
        for (writeIndex, preparedWrite) in preparedWrites.enumerated() {
            switch Self.batchWorkOutcome(at: writeIndex, write: preparedWrite, batch: batchOutcome) {
            case .noFixNeeded:
                await invalidateCaches(for: preparedWrite.change)
                noOpEntries.append(Self.noOpLogEntry(preparedWrite.change))
                continue
            case .failed:
                if let error = batchOutcome.preflightFailures[writeIndex] {
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
            case .fixProposed, .needsReview, .skipped, .deferred, .dismissed, .cancelled:
                assertionFailure("Unexpected terminal batch work outcome")
            }
        }
        if let firstFinalizationError {
            throw firstFinalizationError
        }
        return (entries, noOpEntries)
    }

    private static func batchWorkOutcome(
        at index: Int,
        write: PreparedWrite,
        batch: BatchWriteOutcome
    ) -> WorkOutcome {
        if batch.noOpIndexes.contains(index) {
            return .noFixNeeded
        }
        guard batch.appliedIndexes.contains(index) else {
            return .failed
        }
        let priorValue = batch.currentTracksByID[write.trackID].flatMap { track in
            value(forAppleScriptProperty: write.property, in: track)
        }
        return priorValue == write.value ? .noFixNeeded : .written
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
    ) async throws -> BatchWriteOutcome? {
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
            return BatchWriteOutcome(
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
    ) async throws -> BatchWriteOutcome {
        let writesToApply = preflight.writeIndexes.sorted().map { preparedWrites[$0] }
        let itemIDs = writesToApply.map(\.change.id)
        try await checkpoint?(.beforeAttempt(itemIDs))
        let attemptState = WriteAttemptState()
        do {
            try await scriptBridge.batchUpdateTracks(
                writesToApply.map { write in
                    (trackID: write.trackID, property: write.property, value: write.value)
                },
                onAttempt: {
                    attemptState.markAttempted()
                    try await checkpoint?(.afterAttempt(itemIDs))
                }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WorkCheckpointError {
            throw error
        } catch let error as AppleScriptOutcomeError {
            await invalidateBatchCaches(preparedWrites, indexes: preflight.writeIndexes)
            throw error
        } catch let error as AppleScriptBatchVerificationError {
            return try await verifyBatchAfterFailure(
                preparedWrites,
                currentTracksByID: currentTracksByID,
                preflight: preflight,
                error: error,
                checkpoint: checkpoint
            )
        } catch let error where attemptState.hasAttempted {
            await invalidateBatchCaches(preparedWrites, indexes: preflight.writeIndexes)
            throw AppleScriptOutcomeError(
                scriptName: "batch_update_tracks",
                reason: "returned an error after dispatch: \(error.localizedDescription)"
            )
        } catch {
            throw error
        }

        return BatchWriteOutcome(
            currentTracksByID: currentTracksByID,
            appliedIndexes: preflight.writeIndexes,
            noOpIndexes: preflight.noOpIndexes,
            preflightFailures: preflight.failures
        )
    }

    private func reviewedBatchPreflight(
        _ preparedWrites: [PreparedWrite],
        currentTracksByID: [String: Track],
        isReviewedChange: Bool
    ) throws -> ReviewedBatchPreflight {
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
    ) async throws -> BatchWriteOutcome {
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
                let confirmedIndexes = appliedIndexes.union(preflight.noOpIndexes)
                let batch = BatchWriteOutcome(
                    currentTracksByID: currentTracksByID,
                    appliedIndexes: appliedIndexes,
                    noOpIndexes: preflight.noOpIndexes,
                    preflightFailures: preflight.failures
                )
                try await recordBatchEffects(
                    preparedWrites,
                    batch: batch,
                    indexes: confirmedIndexes
                )
                await invalidateBatchCaches(
                    preparedWrites,
                    indexes: preflight.writeIndexes.subtracting(appliedIndexes)
                )
                try await checkpointBatch(
                    preparedWrites,
                    batch: batch,
                    sink: checkpoint,
                    indexes: confirmedIndexes
                )
                let reason = "verification covered only \(appliedIndexes.count) of \(preflight.writeIndexes.count) " +
                    "writes after dispatch: \(error.localizedDescription)"
                throw AppleScriptOutcomeError(
                    scriptName: "batch_update_tracks",
                    reason: reason
                )
            }
            return BatchWriteOutcome(
                currentTracksByID: currentTracksByID,
                appliedIndexes: appliedIndexes,
                noOpIndexes: preflight.noOpIndexes,
                preflightFailures: preflight.failures
            )
        } catch is CancellationError {
            throw CancellationError()
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

    private func recordBatchEffects(
        _ preparedWrites: [PreparedWrite],
        batch: BatchWriteOutcome,
        indexes: Set<Int>
    ) async throws {
        var firstFinalizationError: (any Error)?
        for index in indexes.sorted() {
            let write = preparedWrites[index]
            switch Self.batchWorkOutcome(at: index, write: write, batch: batch) {
            case .written:
                do {
                    _ = try await recordAppliedChange(write.change)
                } catch {
                    firstFinalizationError = firstFinalizationError ?? error
                }
            case .noFixNeeded:
                await invalidateCaches(for: write.change)
            case .failed, .fixProposed, .needsReview, .skipped, .deferred, .dismissed, .cancelled:
                assertionFailure("Unexpected unconfirmed batch work outcome")
            }
        }
        if let firstFinalizationError {
            throw firstFinalizationError
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

    static func appleScriptProperty(for changeType: ChangeType) -> String {
        switch changeType {
        case .genreUpdate: "genre"
        case .yearUpdate, .yearRevert: "year"
        case .trackCleaning: "name"
        case .albumCleaning: "album"
        case .artistRename: "artist"
        }
    }

    private static func isAlbumYearBatchCandidate(
        _ change: ProposedChange,
        matching firstChange: ProposedChange
    ) -> Bool {
        isAlbumYearBatchCandidate(change)
            && change.newValue == firstChange.newValue
            && hasMatchingAlbumBatchIdentity(change.track, firstChange.track)
    }

    private static func isAlbumYearBatchCandidate(_ change: ProposedChange) -> Bool {
        switch change.changeType {
        case .yearUpdate, .yearRevert:
            change.newValue != nil
        case .genreUpdate, .trackCleaning, .albumCleaning, .artistRename:
            false
        }
    }

    private static func hasMatchingAlbumBatchIdentity(_ track: Track, _ otherTrack: Track) -> Bool {
        let identity = track.albumIdentity
        guard identity.isComplete else { return false }
        return identity.key == otherTrack.albumIdentity.key
    }

    static func value(forAppleScriptProperty property: String, in track: Track) -> String? {
        AppleScriptTrackProperty(rawValue: property)?.currentValue(in: track)
    }

    static func isTrackAvailableForProcessing(_ track: Track) -> Bool {
        track.kind?.isAvailableForProcessing ?? true
    }

    func invalidateCaches(for change: ProposedChange) async {
        for target in Self.cacheInvalidationTargets(for: change, cleaning: runtimeConfiguration.cleaning) {
            await cache.invalidateAlbum(artist: target.artist, album: target.album)
            await cache.invalidateCachedAPIResults(artist: target.artist, album: target.album)
        }
        await librarySnapshotService?.clearSnapshot()
    }

    static func cacheInvalidationTargets(
        for change: ProposedChange,
        cleaning: CleaningConfig? = nil
    ) -> [(artist: String, album: String)] {
        var candidates: [AlbumIdentity] = []
        Self.appendCacheInvalidationIdentities(&candidates, for: change.track, album: change.track.album)

        if change.changeType == .artistRename, let oldArtist = change.oldValue {
            candidates.append(contentsOf: AlbumIdentity.lookupCandidates(
                artist: oldArtist,
                album: change.track.album
            ))
        }
        if change.changeType == .albumCleaning, let oldAlbum = change.oldValue {
            Self.appendCacheInvalidationIdentities(&candidates, for: change.track, album: oldAlbum)
        }
        if change.changeType == .albumCleaning, let newAlbum = change.newValue {
            Self.appendCacheInvalidationIdentities(&candidates, for: change.track, album: newAlbum)
        }
        if let cleaning,
           let cleanedAlbum = Self.cleanedCacheInvalidationAlbum(
               for: change.track,
               cleaning: cleaning
           ) {
            Self.appendCacheInvalidationIdentities(&candidates, for: change.track, album: cleanedAlbum)
        }

        var seenKeys: Set<String> = []
        return candidates.compactMap { identity in
            guard identity.isComplete else { return nil }
            guard seenKeys.insert(identity.key).inserted else { return nil }
            return (artist: identity.artist, album: identity.album)
        }
    }

    private static func appendCacheInvalidationIdentities(
        _ candidates: inout [AlbumIdentity],
        for track: Track,
        album: String
    ) {
        candidates.append(contentsOf: cacheInvalidationIdentities(for: track, album: album))
        if let originalArtist = track.originalArtist {
            candidates.append(contentsOf: AlbumIdentity.lookupCandidates(
                artist: originalArtist,
                album: album
            ))
        }
    }

    private static func cacheInvalidationIdentities(for track: Track, album: String) -> [AlbumIdentity] {
        [
            track.albumIdentity.artist,
            track.effectiveArtist,
            track.artist
        ].flatMap { artist in
            AlbumIdentity.lookupCandidates(artist: artist, album: album)
        }
    }

    private static func cleanedCacheInvalidationAlbum(for track: Track, cleaning: CleaningConfig) -> String? {
        let cleaned = cleanNames(
            artist: track.artist,
            trackName: track.name,
            albumName: track.album,
            config: cleaning
        )
        guard !cleaned.cleanedAlbum.isEmpty,
              normalizedCacheAlbum(cleaned.cleanedAlbum) != normalizedCacheAlbum(track.album)
        else {
            return nil
        }
        return cleaned.cleanedAlbum
    }

    private static func normalizedCacheAlbum(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
