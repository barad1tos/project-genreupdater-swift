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

    func applyReviewedChangeGroup(
        _ changes: [ProposedChange],
        failedTrackIDs: inout [String],
        errorDescriptions: inout [String]
    ) async -> [ChangeLogEntry] {
        if let entries = await applyChangesAsBatchIfPossible(changes) {
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

    func applyChangesAsBatchIfPossible(_ changes: [ProposedChange]) async -> [ChangeLogEntry]? {
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
            } catch {
                log.warning(
                    "Batch write preparation failed; falling back to single writes: \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
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
            guard try await verifyBatchWrites(preparedWrites) else {
                log.warning("Batch AppleScript write could not be verified; falling back to single writes")
                return nil
            }
        } catch {
            log.warning(
                "Batch AppleScript write failed; falling back to single writes: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        var entries: [ChangeLogEntry] = []
        for preparedWrite in preparedWrites {
            let entry = await recordAppliedChange(preparedWrite.change)
            entries.append(entry)
        }
        return entries
    }

    private func verifyBatchWrites(_ preparedWrites: [PreparedAppleScriptWrite]) async throws -> Bool {
        let trackIDs = Array(Set(preparedWrites.map(\.trackID)))
        let refreshedTracks = try await scriptBridge.fetchTracksByIDs(
            trackIDs,
            batchSize: max(trackIDs.count, 1),
            timeout: nil
        )
        let refreshedTracksByID = Dictionary(uniqueKeysWithValues: refreshedTracks.map { ($0.id, $0) })

        return preparedWrites.allSatisfy { preparedWrite in
            guard let refreshedTrack = refreshedTracksByID[preparedWrite.trackID] else {
                return false
            }
            return Self.value(
                forAppleScriptProperty: preparedWrite.property,
                in: refreshedTrack
            ) == preparedWrite.value
        }
    }

    @discardableResult
    func applyChange(_ change: ProposedChange) async throws -> ChangeLogEntry? {
        guard let preparedWrite = try await prepareAppleScriptWrite(for: change) else {
            return nil
        }

        do {
            try await scriptBridge.updateTrackProperty(
                trackID: preparedWrite.trackID,
                property: preparedWrite.property,
                value: preparedWrite.value
            )
        } catch {
            throw UpdateCoordinatorError.writeFailed(
                trackID: change.track.id,
                property: preparedWrite.property,
                reason: error.localizedDescription
            )
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
        var candidates = [(artist: change.track.artist, album: change.track.album)]

        if let originalArtist = change.track.originalArtist {
            candidates.append((artist: originalArtist, album: change.track.album))
        }
        if change.changeType == .artistRename, let oldArtist = change.oldValue {
            candidates.append((artist: oldArtist, album: change.track.album))
        }
        if change.changeType == .albumCleaning, let newAlbum = change.newValue {
            candidates.append((artist: change.track.artist, album: newAlbum))
        }

        var seenKeys: Set<String> = []
        return candidates.compactMap { candidate in
            let artist = candidate.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            let album = candidate.album.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !artist.isEmpty, !album.isEmpty else { return nil }

            let key = "\(normalizeForMatching(artist))\u{1F}\(normalizeForMatching(album))"
            guard seenKeys.insert(key).inserted else { return nil }
            return (artist: artist, album: album)
        }
    }
}
