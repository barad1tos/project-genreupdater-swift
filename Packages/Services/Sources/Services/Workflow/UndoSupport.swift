import Core
import Foundation

private struct YearCheckpointPayload: Codable {
    let entry: ChangeLogEntry
    let phase: BackupRestorePhase
    let historyEntryID: UUID?
    let recoveryOriginYear: Int?
}

extension UndoCoordinator {
    func performRevertWrite(
        change: ProposedChange,
        property: MusicTrackProperty,
        value: String,
        recoveryOrigin: String? = nil,
        revertingHistoryEntryID: UUID? = nil,
        attemptHooks: (
            prepareWrite: ((PreparedWrite) async throws -> Void)?,
            prepareDispatch: ((PreparedWrite) async throws -> Void)?,
            restorePreparedWrite: ((PreparedWrite) async throws -> Void)?
        ) = (nil, nil, nil),
        prepareMirror: ((PreparedWrite, MusicWriteResult) async throws -> Void)? = nil
    ) async throws -> (result: MusicWriteResult, entry: ChangeLogEntry) {
        let preparedWrite = try await prepareRevert(change, property: property, value: value)
        let trackStore = try requiredTrackStore(for: preparedWrite.databaseID.rawValue)

        do {
            try await attemptHooks.prepareWrite?(preparedWrite)
            try await attemptHooks.prepareDispatch?(preparedWrite)
            let attemptState = WriteAttemptState()
            let result: MusicWriteResult
            do {
                result = try await preparedWrite.dispatch(
                    using: musicApp,
                    onAttempt: { attemptState.markAttempted() }
                )
            } catch {
                if !attemptState.hasAttempted {
                    try await attemptHooks.restorePreparedWrite?(preparedWrite)
                }
                throw error
            }
            let entry = UpdateCoordinator.changeToLogEntry(
                preparedWrite.change, databaseID: preparedWrite.databaseID, recoveryOrigin: recoveryOrigin
            )
            do {
                try await prepareMirror?(preparedWrite, result)
                if let revertingHistoryEntryID {
                    _ = try await trackStore.commitRevertedChange(
                        entry,
                        removingHistoryEntryID: revertingHistoryEntryID
                    )
                } else if result == .changed {
                    _ = try await trackStore.commitAppliedChange(entry)
                    await recordCommittedChange(entry)
                } else {
                    _ = try await trackStore.commitObservedChange(entry)
                }
            } catch {
                await invalidateCaches(for: preparedWrite.change)
                if let error = error as? UpdateCoordinatorError {
                    throw error
                }
                throw UpdateCoordinatorError.writeFinalizationFailed(
                    trackID: preparedWrite.databaseID.rawValue,
                    effects: ["track mirror"]
                )
            }
            await invalidateCaches(for: preparedWrite.change)
            return (result, entry)
        } catch {
            switch error {
            case is CancellationError, is UndoCoordinatorError, is UpdateCoordinatorError, is AppleScriptBridgeError:
                throw error
            case is AppleScriptOutcomeError:
                await invalidateCaches(for: preparedWrite.change)
                throw error
            default:
                throw UndoCoordinatorError.revertFailed(
                    trackID: preparedWrite.databaseID.rawValue,
                    reason: "AppleScript write failed"
                )
            }
        }
    }

    func requiredTrackStore(for trackID: String) throws -> any TrackStateStore {
        guard let trackStore else {
            throw UpdateCoordinatorError.writeFinalizationFailed(
                trackID: trackID,
                effects: ["track mirror", "change history"]
            )
        }
        return trackStore
    }

    private func prepareRevert(
        _ change: ProposedChange,
        property: MusicTrackProperty,
        value: String
    ) async throws -> PreparedWrite {
        let mutation = try await mutationContext(for: change.track)
        let albumArtistChange: AlbumArtistChange? = if let change = change.albumArtistChange,
                                                       let current = mutation.track.albumArtist {
            [change.oldValue, change.newValue]
                .map(normalizeForMatching)
                .contains(normalizeForMatching(current)) ? change : nil
        } else {
            nil
        }
        return try PreparedWrite(
            change: change.copy(track: mutation.track, albumArtistChange: albumArtistChange),
            databaseID: mutation.databaseID,
            property: property,
            value: value
        )
    }

    func invalidateCaches(for change: ProposedChange) async {
        if let cache {
            for target in UpdateCoordinator.cacheInvalidationTargets(for: change, cleaning: cleaning) {
                await cache.invalidateAlbum(artist: target.artist, album: target.album)
                await cache.invalidateCachedAPIResults(artist: target.artist, album: target.album)
            }
        }
        await librarySnapshotService?.clearSnapshot()
    }

    func yearRevertChange(
        for historyEntry: ChangeLogEntry,
        context: (change: ProposedChange, oldestEntry: ChangeLogEntry?),
        targetYear: Int
    ) -> ProposedChange {
        ProposedChange(
            id: context.change.id,
            track: context.change.track,
            changeType: .yearRevert,
            oldValue: historyEntry.newYear.map(String.init),
            newValue: String(targetYear),
            confidence: context.change.confidence,
            source: context.change.source
        )
    }

    func recoveryDatabaseID(for trackID: String) async throws -> MusicDatabaseTrackID {
        if let stored = try await storedMutationContext(for: trackID) {
            return stored.databaseID
        }
        if let mappedID = await idMapper?.appleScriptID(forMusicKitID: trackID),
           let databaseID = MusicDatabaseTrackID(rawValue: mappedID) {
            return databaseID
        }
        throw UndoCoordinatorError.missingAppleScriptID(trackID: trackID)
    }

    func mutationContext(for track: Track) async throws -> (track: Track, databaseID: MusicDatabaseTrackID) {
        let expected: (track: Track, databaseID: MusicDatabaseTrackID)
        let requiresKnownStatus: Bool
        if let stored = try await storedMutationContext(for: track.id) {
            expected = stored
            requiresKnownStatus = false
        } else if let databaseID = track.databaseID {
            expected = (track, databaseID)
            requiresKnownStatus = false
        } else {
            let mutationTrack: Track
            if let idMapper {
                guard let enrichedTrack = await idMapper.trackWithAppleScriptMetadata(for: track) else {
                    throw UndoCoordinatorError.missingAppleScriptID(trackID: track.id)
                }
                mutationTrack = enrichedTrack
            } else {
                mutationTrack = track
            }
            guard let idMapper else {
                throw UndoCoordinatorError.missingAppleScriptID(trackID: mutationTrack.id)
            }
            guard let mappedID = await idMapper.appleScriptID(forMusicKitID: mutationTrack.id),
                  let databaseID = MusicDatabaseTrackID(rawValue: mappedID)
            else {
                throw UndoCoordinatorError.missingAppleScriptID(trackID: mutationTrack.id)
            }
            expected = (mutationTrack, databaseID)
            requiresKnownStatus = true
        }

        let observedTracks = try await musicApp.fetchMetadata(for: [expected.databaseID])
        guard let observedTrack = observedTracks.first else {
            throw UndoCoordinatorError.trackUnavailable(trackID: expected.databaseID.rawValue)
        }
        guard observedTracks.count == 1,
              expected.track.name == observedTrack.name,
              expected.track.artist == observedTrack.artist,
              expected.track.album == observedTrack.album,
              expected.track.albumArtist == observedTrack.albumArtist
        else {
            throw UndoCoordinatorError.trackIdentityChanged(trackID: expected.databaseID.rawValue)
        }
        do {
            try UpdateCoordinator.validateMutationEligibility(
                for: observedTrack,
                requiresKnownStatus: requiresKnownStatus
            )
        } catch let error as UpdateCoordinatorError {
            throw UndoCoordinatorError.revertFailed(
                trackID: expected.track.id,
                reason: error.localizedDescription
            )
        }
        return (observedTrack, expected.databaseID)
    }

    private func storedMutationContext(
        for trackID: String
    ) async throws -> (track: Track, databaseID: MusicDatabaseTrackID)? {
        let storedTrack: Track?
        do {
            storedTrack = try await trackStore?.getHistoricalTrack(byID: trackID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw UndoCoordinatorError.recoveryStorageFailed(trackID: trackID)
        }
        guard let storedTrack,
              storedTrack.id == trackID,
              let databaseID = storedTrack.databaseID,
              databaseID.rawValue == trackID
        else {
            return nil
        }
        return (storedTrack, databaseID)
    }

    func revertContext(for entry: ChangeLogEntry) -> (change: ProposedChange, oldestEntry: ChangeLogEntry?) {
        let track = Track(
            id: entry.trackID,
            name: entry.newTrackName ?? entry.trackName,
            artist: entry.newArtist ?? entry.artist,
            album: entry.newAlbumName ?? entry.albumName,
            genre: entry.newGenre,
            year: entry.newYear,
            albumArtist: entry.albumArtistChange?.newValue
        )
        let values: (oldValue: String?, newValue: String?) = switch entry.changeType {
        case .genreUpdate:
            (entry.oldGenre, entry.newGenre)
        case .yearUpdate, .yearRevert:
            (String(entry.oldYear ?? MusicAppYear.missingValue), entry.newYear.map(String.init))
        case .trackCleaning:
            (entry.oldTrackName, entry.newTrackName)
        case .albumCleaning:
            (entry.oldAlbumName, entry.newAlbumName)
        case .artistRename:
            (entry.oldArtist, entry.newArtist)
        }
        let change = ProposedChange(
            track: track,
            changeType: entry.changeType,
            oldValue: values.newValue,
            newValue: values.oldValue,
            confidence: 100,
            source: "undo",
            albumArtistChange: entry.albumArtistChange.map {
                AlbumArtistChange(oldValue: $0.newValue, newValue: $0.oldValue)
            }
        )
        let oldestEntry = history
            .filter { candidate in
                guard candidate.trackID == entry.trackID else { return false }
                return switch entry.changeType {
                case .yearUpdate, .yearRevert:
                    candidate.changeType == .yearUpdate || candidate.changeType == .yearRevert
                case .albumCleaning:
                    candidate.changeType == .albumCleaning
                case .artistRename:
                    candidate.changeType == .artistRename
                case .genreUpdate, .trackCleaning:
                    false
                }
            }
            .min { $0.timestamp < $1.timestamp }
        return (change, oldestEntry)
    }

    func backupCheckpoint(
        for trackID: String,
        targetYear: Int? = nil,
        observedYear: Int? = nil,
        writing checkpoint: (
            entry: ChangeLogEntry,
            metadata: (phase: BackupRestorePhase, historyEntryID: UUID?, originYear: Int?)
        )? = nil,
        shouldRemove: Bool = false,
        purpose: YearCheckpointPurpose = .backupRestore,
        effect: String = "backup recovery checkpoint"
    ) throws -> (
        entry: ChangeLogEntry,
        metadata: (phase: BackupRestorePhase, historyEntryID: UUID?, originYear: Int?)
    )? {
        if !shouldRemove, checkpoint == nil, !fileManager.fileExists(atPath: backupCheckpointURL.path) {
            return nil
        }
        do {
            if shouldRemove {
                try fileManager.removeItem(at: backupCheckpointURL)
                return nil
            }
            if let checkpoint {
                try fileManager.createDirectory(
                    at: backupCheckpointURL.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                let payload = YearCheckpointPayload(
                    entry: checkpoint.entry,
                    phase: checkpoint.metadata.phase,
                    historyEntryID: checkpoint.metadata.historyEntryID,
                    recoveryOriginYear: checkpoint.metadata.originYear
                )
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(payload).write(to: backupCheckpointURL, options: .atomic)
                return checkpoint
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(YearCheckpointPayload.self, from: Data(contentsOf: backupCheckpointURL))
            try validateBackupCheckpoint(payload, trackID: trackID, targetYear: targetYear, observedYear: observedYear)
            return (payload.entry, (payload.phase, payload.historyEntryID, payload.recoveryOriginYear))
        } catch let error as UpdateCoordinatorError {
            throw error
        } catch {
            switch purpose {
            case .backupRestore:
                throw UpdateCoordinatorError.writeFinalizationFailed(trackID: trackID, effects: [effect])
            case .historyUndo:
                throw UndoCoordinatorError.recoveryStorageFailed(trackID: trackID)
            }
        }
    }

    private func validateBackupCheckpoint(
        _ payload: YearCheckpointPayload,
        trackID: String,
        targetYear: Int?,
        observedYear: Int?
    ) throws {
        guard let targetYear else { return }
        guard payload.historyEntryID == nil,
              payload.entry.changeType == .yearRevert,
              payload.entry.trackID == trackID,
              payload.entry.newYear == targetYear
        else {
            throw UpdateCoordinatorError.writeFinalizationFailed(
                trackID: payload.entry.trackID, effects: ["prior backup recovery checkpoint"]
            )
        }
        guard payload.phase != .dispatchedUnknown else {
            throw UpdateCoordinatorError.writeFinalizationFailed(
                trackID: trackID, effects: ["ambiguous backup write outcome"]
            )
        }
        let expectedYear = payload.phase == .prepared ? payload.entry.oldYear : targetYear
        guard observedYear == expectedYear else {
            throw UpdateCoordinatorError.writeFinalizationFailed(
                trackID: trackID, effects: ["stale backup recovery checkpoint"]
            )
        }
    }

    static func publicFailureDescription(for error: Error) -> String {
        if let undoError = error as? UndoCoordinatorError {
            switch undoError {
            case let .revertFailed(_, reason):
                return reason == "AppleScript write failed" ? reason : "Failed to revert track"
            case .trackUnavailable,
                 .trackIdentityChanged:
                return undoError.errorDescription ?? "Undo safety check failed"
            case .noChangesToRevert,
                 .invalidBackupCSV,
                 .missingAppleScriptID,
                 .historyStoreUnavailable,
                 .undoOutcomeUnknown,
                 .undoWriteNotApplied,
                 .undoRecoveryConflict,
                 .recoveryStorageFailed:
                return undoError.errorDescription ?? "Undo operation failed"
            case let .partialRevertFailure(succeeded, failed, _):
                return "Partial revert: \(succeeded) succeeded, \(failed) failed"
            }
        }
        if let appleScriptError = error as? AppleScriptBridgeError {
            return switch appleScriptError {
            case .dispatchDeadline,
                 .invalidLibraryPath,
                 .libraryChanged,
                 .scriptNotFound,
                 .scriptsNotInstalled,
                 .musicAppNotRunning,
                 .timeout:
                appleScriptError.errorDescription ?? "AppleScript write failed"
            case .executionFailed:
                "AppleScript write failed"
            case .parseError:
                "AppleScript output could not be parsed"
            }
        }
        if let outcomeError = error as? AppleScriptOutcomeError {
            return outcomeError.localizedDescription
        }
        return "AppleScript write failed"
    }

    static func loadPersistedHistory(from url: URL) -> [ChangeLogEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ChangeLogEntry].self, from: data)) ?? []
    }

    func loadHistoryFromStoreOrLegacy() async throws -> [ChangeLogEntry] {
        guard let changeLogStore else {
            return Self.loadPersistedHistory(from: legacyHistoryURL)
        }

        let storedHistory = try await changeLogStore.loadAll()
        guard storedHistory.isEmpty else {
            return storedHistory
        }

        let legacyHistory = Self.loadPersistedHistory(from: legacyHistoryURL)
        if !legacyHistory.isEmpty {
            try await changeLogStore.saveEntries(legacyHistory)
        }
        return legacyHistory
    }

    static func defaultDirectory() -> URL {
        let directories = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )
        guard let appSupport = directories.first else {
            return URL(fileURLWithPath: NSTemporaryDirectory())
        }
        return appSupport.appendingPathComponent("GenreUpdater", isDirectory: true)
    }
}
