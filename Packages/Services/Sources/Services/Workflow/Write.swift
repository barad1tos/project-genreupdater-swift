import Core
import Foundation

private struct PreparedAppleScriptWrite {
    let change: ProposedChange
    let trackID: String
    let property: String
    let value: String
}

private enum PreparedAppleScriptWriteOutcome {
    case write(PreparedAppleScriptWrite)
    case noOp(ChangeLogEntry)
    case skipped
}

private struct BatchWriteOutcome {
    let currentTracksByID: [String: Track]
    let appliedIndexes: Set<Int>
    let noOpIndexes: Set<Int>
}

private struct ReviewedBatchPreflight {
    let writeIndexes: Set<Int>
    let noOpIndexes: Set<Int>
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
        errorDescriptions: inout [String]
    ) async throws -> AppliedChangeEntries {
        if let applied = try await applyChangesAsBatchIfPossible(
            changes,
            isReviewedChange: true,
            failedTrackIDs: &failedTrackIDs,
            errorDescriptions: &errorDescriptions
        ) {
            return applied
        }

        var entries: [ChangeLogEntry] = []
        var noOpEntries: [ChangeLogEntry] = []
        for change in changes {
            do {
                let outcome = try await applyChangeOutcome(change, isReviewedChange: true)
                if let entry = outcome.entry {
                    entries.append(entry)
                }
                if let noOpEntry = outcome.noOpEntry {
                    noOpEntries.append(noOpEntry)
                }
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
        errorDescriptions: inout [String]
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
                isReviewedChange: isReviewedChange
            ) else {
                return nil
            }
            batchOutcome = verifiedBatchOutcome
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AppleScriptOutcomeError {
            throw error
        } catch let error as UpdateCoordinatorError {
            throw error
        } catch {
            log.warning(
                "Batch AppleScript write failed; falling back to single writes: \(error.localizedDescription, privacy: .private)"
            )
            return nil
        }

        return await appliedChangeEntries(
            for: preparedWrites,
            batchOutcome: batchOutcome,
            failedTrackIDs: &failedTrackIDs,
            errorDescriptions: &errorDescriptions
        )
    }

    private func appliedChangeEntries(
        for preparedWrites: [PreparedAppleScriptWrite],
        batchOutcome: BatchWriteOutcome,
        failedTrackIDs: inout [String],
        errorDescriptions: inout [String]
    ) async -> AppliedChangeEntries {
        var entries: [ChangeLogEntry] = []
        var noOpEntries: [ChangeLogEntry] = []
        for (writeIndex, preparedWrite) in preparedWrites.enumerated() {
            if batchOutcome.noOpIndexes.contains(writeIndex) {
                await invalidateCaches(for: preparedWrite.change)
                noOpEntries.append(Self.noOpLogEntry(preparedWrite.change))
                continue
            }

            guard batchOutcome.appliedIndexes.contains(writeIndex) else {
                await recordUnverifiedBatchWrite(
                    preparedWrite,
                    failedTrackIDs: &failedTrackIDs,
                    errorDescriptions: &errorDescriptions
                )
                continue
            }

            let currentValue = batchOutcome.currentTracksByID[preparedWrite.trackID].flatMap { currentTrack in
                Self.value(forAppleScriptProperty: preparedWrite.property, in: currentTrack)
            }
            guard currentValue != preparedWrite.value else {
                await invalidateCaches(for: preparedWrite.change)
                log
                    .info(
                        "Skipped applied-change record for verified batch no-op \(preparedWrite.change.changeType.rawValue, privacy: .public) on track \(preparedWrite.change.track.id, privacy: .private)"
                    )
                noOpEntries.append(Self.noOpLogEntry(preparedWrite.change))
                continue
            }

            let entry = await recordAppliedChange(preparedWrite.change)
            entries.append(entry)
        }
        return (entries, noOpEntries)
    }

    private func recordUnverifiedBatchWrite(
        _ preparedWrite: PreparedAppleScriptWrite,
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
    ) async throws -> [PreparedAppleScriptWrite]? {
        var preparedWrites: [PreparedAppleScriptWrite] = []
        for change in changes {
            do {
                let outcome = try await prepareAppleScriptWrite(
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
                log.warning(
                    "Batch write preparation failed; falling back to single writes: \(error.localizedDescription, privacy: .private)"
                )
                return nil
            }
        }
        return preparedWrites
    }

    private func performVerifiedBatchWrite(
        _ preparedWrites: [PreparedAppleScriptWrite],
        isReviewedChange: Bool
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
                noOpIndexes: preflight.noOpIndexes
            )
        }

        let writesToApply = preflight.writeIndexes.sorted().map { preparedWrites[$0] }
        do {
            try await scriptBridge.batchUpdateTracks(
                writesToApply.map { preparedWrite in
                    (
                        trackID: preparedWrite.trackID,
                        property: preparedWrite.property,
                        value: preparedWrite.value
                    )
                }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AppleScriptOutcomeError {
            await invalidateBatchCaches(preparedWrites, indexes: preflight.writeIndexes)
            throw error
        } catch let error as AppleScriptBatchVerificationError {
            return try await batchOutcomeAfterPostRunVerificationFailure(
                preparedWrites,
                currentTracksByID: currentTracksByID,
                attemptedIndexes: preflight.writeIndexes,
                noOpIndexes: preflight.noOpIndexes,
                error: error
            )
        } catch {
            throw error
        }

        return BatchWriteOutcome(
            currentTracksByID: currentTracksByID,
            appliedIndexes: preflight.writeIndexes,
            noOpIndexes: preflight.noOpIndexes
        )
    }

    private func reviewedBatchPreflight(
        _ preparedWrites: [PreparedAppleScriptWrite],
        currentTracksByID: [String: Track],
        isReviewedChange: Bool
    ) throws -> ReviewedBatchPreflight {
        guard isReviewedChange else {
            return ReviewedBatchPreflight(
                writeIndexes: Set(preparedWrites.indices),
                noOpIndexes: []
            )
        }

        var writeIndexes = Set<Int>()
        var noOpIndexes = Set<Int>()
        for (index, preparedWrite) in preparedWrites.enumerated() {
            guard let currentTrack = currentTracksByID[preparedWrite.trackID] else {
                continue
            }
            let shouldWrite = try shouldWriteReviewedChange(
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
        }
        return ReviewedBatchPreflight(writeIndexes: writeIndexes, noOpIndexes: noOpIndexes)
    }

    private func batchOutcomeAfterPostRunVerificationFailure(
        _ preparedWrites: [PreparedAppleScriptWrite],
        currentTracksByID: [String: Track],
        attemptedIndexes: Set<Int>,
        noOpIndexes: Set<Int>,
        error: AppleScriptBatchVerificationError
    ) async throws -> BatchWriteOutcome {
        do {
            guard let appliedIndexes = try await verifiedBatchWriteIndexes(
                preparedWrites,
                attemptedIndexes: attemptedIndexes
            ) else {
                await invalidateBatchCaches(preparedWrites, indexes: attemptedIndexes)
                throw AppleScriptOutcomeError(
                    scriptName: "batch_update_tracks",
                    reason: "could not verify metadata after dispatch: \(error.localizedDescription)"
                )
            }
            guard appliedIndexes == attemptedIndexes else {
                await invalidateBatchCaches(preparedWrites, indexes: attemptedIndexes)
                throw AppleScriptOutcomeError(
                    scriptName: "batch_update_tracks",
                    reason: "verification covered only \(appliedIndexes.count) of \(attemptedIndexes.count) writes after dispatch: \(error.localizedDescription)"
                )
            }
            return BatchWriteOutcome(
                currentTracksByID: currentTracksByID,
                appliedIndexes: appliedIndexes,
                noOpIndexes: noOpIndexes
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let outcome as AppleScriptOutcomeError {
            throw outcome
        } catch {
            await invalidateBatchCaches(preparedWrites, indexes: attemptedIndexes)
            throw AppleScriptOutcomeError(
                scriptName: "batch_update_tracks",
                reason: "verification failed after dispatch: \(error.localizedDescription)"
            )
        }
    }

    private func invalidateBatchCaches(
        _ preparedWrites: [PreparedAppleScriptWrite],
        indexes: Set<Int>
    ) async {
        for index in indexes.sorted() {
            await invalidateCaches(for: preparedWrites[index].change)
        }
    }

    private func fetchBatchWriteTracks(_ preparedWrites: [PreparedAppleScriptWrite]) async throws -> [String: Track]? {
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

    private func verifiedBatchWriteIndexes(
        _ preparedWrites: [PreparedAppleScriptWrite],
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

    @discardableResult
    func applyChange(
        _ change: ProposedChange,
        isReviewedChange: Bool = true
    ) async throws -> ChangeLogEntry? {
        try await applyChangeOutcome(change, isReviewedChange: isReviewedChange).entry
    }

    func applyChangeOutcome(
        _ change: ProposedChange,
        isReviewedChange: Bool = true
    ) async throws -> AppliedChangeOutcome {
        let preparedOutcome = try await prepareAppleScriptWrite(
            for: change,
            isReviewedChange: isReviewedChange
        )
        let preparedWrite: PreparedAppleScriptWrite
        switch preparedOutcome {
        case let .write(write):
            preparedWrite = write
        case let .noOp(noOpEntry):
            await invalidateCaches(for: change)
            return (nil, noOpEntry)
        case .skipped:
            return (nil, nil)
        }

        let writeResult: AppleScriptWriteResult
        do {
            writeResult = try await scriptBridge.updateTrackProperty(
                trackID: preparedWrite.trackID,
                property: preparedWrite.property,
                value: preparedWrite.value
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AppleScriptOutcomeError {
            await invalidateCaches(for: change)
            throw error
        } catch {
            throw UpdateCoordinatorError.writeFailed(
                trackID: change.track.id,
                property: preparedWrite.property,
                reason: error.localizedDescription
            )
        }

        guard writeResult == .changed else {
            await invalidateCaches(for: change)
            log
                .info(
                    "Skipped applied-change record for no-op \(change.changeType.rawValue, privacy: .public) on track \(change.track.id, privacy: .private)"
                )
            return (nil, Self.noOpLogEntry(change))
        }

        return await (recordAppliedChange(change), nil)
    }

    private func prepareAppleScriptWrite(
        for change: ProposedChange,
        isReviewedChange: Bool = true
    ) async throws -> PreparedAppleScriptWriteOutcome {
        guard runtimeConfiguration.allowsChange(change) else {
            log
                .info(
                    "Skipped change for track \(change.track.id, privacy: .private) outside test artist allow-list"
                )
            return .skipped
        }

        guard let newValue = change.newValue else { return .skipped }
        let mutationTrack = try await trackWithMutationMetadata(change.track)
        guard mutationTrack.canEdit else {
            throw UpdateCoordinatorError.trackNotEditable(trackID: mutationTrack.id)
        }
        guard Self.isTrackAvailableForProcessing(mutationTrack) else {
            throw UpdateCoordinatorError.trackNotProcessable(
                trackID: mutationTrack.id,
                status: mutationTrack.trackStatus ?? "unknown"
            )
        }
        let property = Self.appleScriptProperty(for: change.changeType)
        if isReviewedChange {
            guard try shouldWriteReviewedChange(change, to: mutationTrack, property: property) else {
                log.info(
                    "Skipped reviewed \(change.changeType.rawValue, privacy: .public) for track \(change.track.id, privacy: .private) after write preflight"
                )
                return .noOp(Self.noOpLogEntry(change))
            }
        }

        let writeID: String
        if let idMapper {
            guard let appleScriptID = await idMapper.appleScriptID(forMusicKitID: mutationTrack.id) else {
                throw UpdateCoordinatorError.missingAppleScriptID(trackID: mutationTrack.id)
            }
            writeID = appleScriptID
        } else {
            writeID = mutationTrack.id
        }

        return .write(
            PreparedAppleScriptWrite(
                change: change,
                trackID: writeID,
                property: property,
                value: newValue
            )
        )
    }

    private func shouldWriteReviewedChange(
        _ change: ProposedChange,
        to mutationTrack: Track,
        property: String,
        staleTrackID: String? = nil
    ) throws -> Bool {
        if change.changeType == .yearUpdate, mutationTrack.hasBeenProcessed {
            return false
        }
        guard Self.valueMatches(change.oldValue, in: mutationTrack, property: property) ||
            Self.valueMatches(change.newValue, in: mutationTrack, property: property)
        else {
            throw UpdateCoordinatorError.reviewedChangeStale(
                trackID: staleTrackID ?? mutationTrack.id,
                property: property
            )
        }
        return true
    }

    private static func valueMatches(_ expectedValue: String?, in track: Track, property: String) -> Bool {
        normalizedReviewedValue(expectedValue) == normalizedReviewedValue(value(
            forAppleScriptProperty: property,
            in: track
        ))
    }

    private static func normalizedReviewedValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func recordAppliedChange(_ change: ProposedChange) async -> ChangeLogEntry {
        let logEntry = Self.changeToLogEntry(change)
        await undoCoordinator.recordChange(logEntry)

        try? await trackStore.updateTrackProcessingState(
            id: change.track.id,
            genreUpdated: change.changeType == .genreUpdate ? true : nil,
            yearUpdated: change.changeType == .yearUpdate || change.changeType == .yearRevert ? true : nil
        )
        await invalidateCaches(for: change)

        log
            .info(
                "Applied \(change.changeType.rawValue, privacy: .public) to track \(change.track.id, privacy: .private)"
            )
        return logEntry
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

    private static func value(forAppleScriptProperty property: String, in track: Track) -> String? {
        AppleScriptTrackProperty(rawValue: property)?.currentValue(in: track)
    }

    static func isTrackAvailableForProcessing(_ track: Track) -> Bool {
        track.kind?.isAvailableForProcessing ?? true
    }

    private func invalidateCaches(for change: ProposedChange) async {
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
