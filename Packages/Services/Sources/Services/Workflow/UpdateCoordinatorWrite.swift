import Core
import Foundation

private struct PreparedAppleScriptWrite {
    let change: ProposedChange
    let trackID: String
    let property: String
    let value: String
}

extension UpdateCoordinator {
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
    ) async throws -> [ChangeLogEntry] {
        if let entries = try await applyChangesAsBatchIfPossible(changes) {
            return entries
        }

        var entries: [ChangeLogEntry] = []
        for change in changes {
            do {
                if let entry = try await applyChange(change) {
                    entries.append(entry)
                }
            } catch let error as UpdateCoordinatorError {
                if !recordKnownWorkflowFailure(
                    error,
                    fallbackTrackID: change.track.id,
                    isReviewedChange: true,
                    failedTrackIDs: &failedTrackIDs,
                    errorDescriptions: &errorDescriptions
                ) {
                    recordUnexpectedWorkflowFailure(
                        trackID: change.track.id,
                        error: error,
                        failedTrackIDs: &failedTrackIDs,
                        errorDescriptions: &errorDescriptions
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                recordUnexpectedWorkflowFailure(
                    trackID: change.track.id,
                    error: error,
                    failedTrackIDs: &failedTrackIDs,
                    errorDescriptions: &errorDescriptions
                )
            }
        }
        return entries
    }

    func applyChangesAsBatchIfPossible(_ changes: [ProposedChange]) async throws -> [ChangeLogEntry]? {
        guard runtimeConfiguration.areBatchUpdatesEnabled,
              changes.count > 1,
              changes.count <= runtimeConfiguration.maxBatchUpdateSize
        else {
            return nil
        }

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

        let currentTracksByID: [String: Track]
        do {
            guard let fetchedCurrentTracksByID = try await performVerifiedBatchWrite(preparedWrites) else {
                return nil
            }
            currentTracksByID = fetchedCurrentTracksByID
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.warning(
                "Batch AppleScript write failed; falling back to single writes: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        var entries: [ChangeLogEntry] = []
        for preparedWrite in preparedWrites {
            let currentValue = currentTracksByID[preparedWrite.trackID].flatMap { currentTrack in
                Self.value(forAppleScriptProperty: preparedWrite.property, in: currentTrack)
            }
            guard currentValue != preparedWrite.value else {
                await invalidateCaches(for: preparedWrite.change)
                log
                    .info(
                        "Skipped applied-change record for verified batch no-op \(preparedWrite.change.changeType.rawValue, privacy: .public) on track \(preparedWrite.change.track.id, privacy: .private)"
                    )
                continue
            }

            let entry = await recordAppliedChange(preparedWrite.change)
            entries.append(entry)
        }
        return entries
    }

    private func performVerifiedBatchWrite(
        _ preparedWrites: [PreparedAppleScriptWrite]
    ) async throws -> [String: Track]? {
        guard let currentTracksByID = try await fetchBatchWriteTracks(preparedWrites) else {
            log.warning(
                "Batch AppleScript write preflight could not fetch current tracks; falling back to single writes"
            )
            return nil
        }

        try await scriptBridge.batchUpdateTracks(
            preparedWrites.map { preparedWrite in
                (
                    trackID: preparedWrite.trackID,
                    property: preparedWrite.property,
                    value: preparedWrite.value
                )
            }
        )
        guard try await verifyBatchWrites(preparedWrites) != nil else {
            log.warning("Batch AppleScript write could not be verified; falling back to single writes")
            return nil
        }
        return currentTracksByID
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

    private func verifyBatchWrites(_ preparedWrites: [PreparedAppleScriptWrite]) async throws -> [String: Track]? {
        guard let refreshedTracksByID = try await fetchBatchWriteTracks(preparedWrites) else {
            return nil
        }

        let isVerified = preparedWrites.allSatisfy { preparedWrite in
            guard let refreshedTrack = refreshedTracksByID[preparedWrite.trackID] else {
                return false
            }
            return Self.value(
                forAppleScriptProperty: preparedWrite.property,
                in: refreshedTrack
            ) == preparedWrite.value
        }
        return isVerified ? refreshedTracksByID : nil
    }

    @discardableResult
    func applyChange(_ change: ProposedChange) async throws -> ChangeLogEntry? {
        guard let preparedWrite = try await prepareAppleScriptWrite(for: change) else {
            return nil
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
            return nil
        }

        return await recordAppliedChange(change)
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
        for target in cacheInvalidationTargets(for: change) {
            await cache.invalidateAlbum(artist: target.artist, album: target.album)
            await cache.invalidateCachedAPIResults(artist: target.artist, album: target.album)
        }
        await librarySnapshotService?.clearSnapshot()
    }

    private func cacheInvalidationTargets(for change: ProposedChange) -> [(artist: String, album: String)] {
        var candidates = Self.cacheInvalidationIdentities(
            for: change.track,
            album: change.track.album
        )

        if let originalArtist = change.track.originalArtist {
            candidates.append(contentsOf: AlbumIdentity.lookupCandidates(
                artist: originalArtist,
                album: change.track.album
            ))
        }
        if change.changeType == .artistRename, let oldArtist = change.oldValue {
            candidates.append(contentsOf: AlbumIdentity.lookupCandidates(
                artist: oldArtist,
                album: change.track.album
            ))
        }
        if change.changeType == .albumCleaning, let newAlbum = change.newValue {
            candidates.append(contentsOf: Self.cacheInvalidationIdentities(
                for: change.track,
                album: newAlbum
            ))
            if let originalArtist = change.track.originalArtist {
                candidates.append(contentsOf: AlbumIdentity.lookupCandidates(
                    artist: originalArtist,
                    album: newAlbum
                ))
            }
        }
        if let cleanedAlbum = Self.cleanedCacheInvalidationAlbum(
            for: change.track,
            cleaning: runtimeConfiguration.cleaning
        ) {
            candidates.append(contentsOf: Self.cacheInvalidationIdentities(
                for: change.track,
                album: cleanedAlbum
            ))
            if let originalArtist = change.track.originalArtist {
                candidates.append(contentsOf: AlbumIdentity.lookupCandidates(
                    artist: originalArtist,
                    album: cleanedAlbum
                ))
            }
        }

        var seenKeys: Set<String> = []
        return candidates.compactMap { identity in
            guard identity.isComplete else { return nil }
            guard seenKeys.insert(identity.key).inserted else { return nil }
            return (artist: identity.artist, album: identity.album)
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
