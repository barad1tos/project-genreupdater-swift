import Core
import Foundation

private struct PreparedAppleScriptWrite {
    let change: ProposedChange
    let trackID: String
    let property: String
    let value: String
}

private struct BatchWriteOutcome {
    let currentTracksByID: [String: Track]
    let appliedIndexes: Set<Int>
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
            failedTrackIDs: &failedTrackIDs,
            errorDescriptions: &errorDescriptions
        ) {
            return applied
        }

        var entries: [ChangeLogEntry] = []
        var noOpEntries: [ChangeLogEntry] = []
        for change in changes {
            do {
                let outcome = try await applyChangeOutcome(change)
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

    func recordWorkflowWriteFailure(
        _ error: any Error,
        isReviewedChange: Bool,
        trackID: String,
        failedTrackIDs: inout [String],
        errorDescriptions: inout [String]
    ) throws {
        if error is CancellationError {
            throw CancellationError()
        }
        if let coordinatorError = error as? UpdateCoordinatorError,
           recordKnownWorkflowFailure(
               coordinatorError,
               fallbackTrackID: trackID,
               isReviewedChange: isReviewedChange,
               failedTrackIDs: &failedTrackIDs,
               errorDescriptions: &errorDescriptions
           ) {
            return
        }
        recordUnexpectedWorkflowFailure(
            trackID: trackID,
            error: error,
            failedTrackIDs: &failedTrackIDs,
            errorDescriptions: &errorDescriptions
        )
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
            failedTrackIDs: &failedTrackIDs,
            errorDescriptions: &errorDescriptions
        ) {
            return applied
        }

        var entries: [ChangeLogEntry] = []
        var noOpEntries: [ChangeLogEntry] = []
        for change in acceptedChanges {
            do {
                let outcome = try await applyChangeOutcome(change)
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
        failedTrackIDs: inout [String],
        errorDescriptions: inout [String]
    ) async throws -> AppliedChangeEntries? {
        guard runtimeConfiguration.areBatchUpdatesEnabled,
              changes.count > 1,
              changes.count <= runtimeConfiguration.maxBatchUpdateSize
        else {
            return nil
        }

        guard let preparedWrites = try await prepareBatchWrites(changes) else {
            return nil
        }

        let batchOutcome: BatchWriteOutcome
        do {
            guard let verifiedBatchOutcome = try await performVerifiedBatchWrite(preparedWrites) else {
                return nil
            }
            batchOutcome = verifiedBatchOutcome
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as UpdateCoordinatorError {
            throw error
        } catch {
            log.warning(
                "Batch AppleScript write failed; falling back to single writes: \(error.localizedDescription, privacy: .public)"
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
        recordUnexpectedWorkflowFailure(
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

    private func prepareBatchWrites(_ changes: [ProposedChange]) async throws -> [PreparedAppleScriptWrite]? {
        var preparedWrites: [PreparedAppleScriptWrite] = []
        for change in changes {
            do {
                guard let preparedWrite = try await prepareAppleScriptWrite(for: change) else {
                    return nil
                }
                preparedWrites.append(preparedWrite)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log.warning(
                    "Batch write preparation failed; falling back to single writes: \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        }
        return preparedWrites
    }

    private func performVerifiedBatchWrite(
        _ preparedWrites: [PreparedAppleScriptWrite]
    ) async throws -> BatchWriteOutcome? {
        guard let currentTracksByID = try await fetchBatchWriteTracks(preparedWrites) else {
            log.warning(
                "Batch AppleScript write preflight could not fetch current tracks; falling back to single writes"
            )
            return nil
        }

        do {
            try await scriptBridge.batchUpdateTracks(
                preparedWrites.map { preparedWrite in
                    (
                        trackID: preparedWrite.trackID,
                        property: preparedWrite.property,
                        value: preparedWrite.value
                    )
                }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AppleScriptBatchVerificationError {
            return try await batchOutcomeAfterPostRunVerificationFailure(
                preparedWrites,
                currentTracksByID: currentTracksByID,
                error: error
            )
        } catch {
            throw error
        }

        guard let appliedIndexes = try await verifiedBatchWriteIndexes(preparedWrites) else {
            log.warning("Batch AppleScript write could not be verified; unverified writes are failures")
            return BatchWriteOutcome(currentTracksByID: currentTracksByID, appliedIndexes: [])
        }
        guard !appliedIndexes.isEmpty else {
            log.warning("Batch AppleScript write did not verify any updates; unverified writes are failures")
            return BatchWriteOutcome(currentTracksByID: currentTracksByID, appliedIndexes: [])
        }
        if appliedIndexes.count < preparedWrites.count {
            log.warning(
                "Batch AppleScript write partially verified; unverified writes are failures"
            )
        }
        return BatchWriteOutcome(currentTracksByID: currentTracksByID, appliedIndexes: appliedIndexes)
    }

    private func batchOutcomeAfterPostRunVerificationFailure(
        _ preparedWrites: [PreparedAppleScriptWrite],
        currentTracksByID: [String: Track],
        error: AppleScriptBatchVerificationError
    ) async throws -> BatchWriteOutcome {
        do {
            guard let appliedIndexes = try await verifiedBatchWriteIndexes(preparedWrites) else {
                log.warning(
                    "Batch AppleScript write could not be verified after script ran; unverified writes are failures: \(error.localizedDescription, privacy: .public)"
                )
                return BatchWriteOutcome(currentTracksByID: currentTracksByID, appliedIndexes: [])
            }
            guard !appliedIndexes.isEmpty else {
                log.warning(
                    "Batch AppleScript write reported no verified updates after script ran; unverified writes are failures: \(error.localizedDescription, privacy: .public)"
                )
                return BatchWriteOutcome(currentTracksByID: currentTracksByID, appliedIndexes: [])
            }
            log.warning(
                "Batch AppleScript write reported failure after partial verification; unverified writes are failures: \(error.localizedDescription, privacy: .public)"
            )
            return BatchWriteOutcome(currentTracksByID: currentTracksByID, appliedIndexes: appliedIndexes)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.warning(
                "Batch AppleScript write verification failed after script ran; unverified writes are failures: \(error.localizedDescription, privacy: .public)"
            )
            return BatchWriteOutcome(currentTracksByID: currentTracksByID, appliedIndexes: [])
        }
    }

    private func fetchBatchWriteTracks(_ preparedWrites: [PreparedAppleScriptWrite]) async throws -> [String: Track]? {
        let trackIDs = Array(Set(preparedWrites.map(\.trackID)))
        let fetchedTracks = try await scriptBridge.fetchTracksByIDs(
            trackIDs,
            batchSize: max(trackIDs.count, 1),
            timeout: nil
        )
        let fetchedTracksByID = Dictionary(uniqueKeysWithValues: fetchedTracks.map { ($0.id, $0) })
        let hasAllTracks = trackIDs.allSatisfy { fetchedTracksByID[$0] != nil }
        return hasAllTracks ? fetchedTracksByID : nil
    }

    private func verifiedBatchWriteIndexes(
        _ preparedWrites: [PreparedAppleScriptWrite]
    ) async throws -> Set<Int>? {
        guard let refreshedTracksByID = try await fetchBatchWriteTracks(preparedWrites) else {
            return nil
        }

        var appliedIndexes = Set<Int>()
        for (index, preparedWrite) in preparedWrites.enumerated() {
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
    func applyChange(_ change: ProposedChange) async throws -> ChangeLogEntry? {
        try await applyChangeOutcome(change).entry
    }

    func applyChangeOutcome(_ change: ProposedChange) async throws -> AppliedChangeOutcome {
        guard let preparedWrite = try await prepareAppleScriptWrite(for: change) else {
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

    private func prepareAppleScriptWrite(for change: ProposedChange) async throws -> PreparedAppleScriptWrite? {
        guard runtimeConfiguration.allowsChange(change) else {
            log
                .info(
                    "Skipped change for track \(change.track.id, privacy: .private) outside test artist allow-list"
                )
            return nil
        }

        guard let newValue = change.newValue else { return nil }
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

        let writeID: String
        if let idMapper {
            guard let appleScriptID = await idMapper.appleScriptID(forMusicKitID: mutationTrack.id) else {
                throw UpdateCoordinatorError.missingAppleScriptID(trackID: mutationTrack.id)
            }
            writeID = appleScriptID
        } else {
            writeID = mutationTrack.id
        }

        return PreparedAppleScriptWrite(
            change: change,
            trackID: writeID,
            property: property,
            value: newValue
        )
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
        switch property {
        case "genre":
            track.genre
        case "year":
            track.year.map(String.init)
        case "name":
            track.name
        case "album":
            track.album
        case "artist":
            track.artist
        default:
            nil
        }
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
            track.artist,
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
