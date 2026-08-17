import Core
import Foundation

extension UndoCoordinator {
    func mutationContext(for track: Track) async throws -> (track: Track, writeID: String) {
        let mutationTrack: Track
        if let idMapper {
            guard let enrichedTrack = await idMapper.trackWithAppleScriptMetadata(for: track) else {
                throw UndoCoordinatorError.missingAppleScriptID(trackID: track.id)
            }
            mutationTrack = enrichedTrack
        } else {
            mutationTrack = track
        }
        do {
            try UpdateCoordinator.validateMutationEligibility(
                for: mutationTrack,
                requiresKnownStatus: idMapper != nil
            )
        } catch let error as UpdateCoordinatorError {
            throw UndoCoordinatorError.revertFailed(
                trackID: mutationTrack.id,
                reason: error.localizedDescription
            )
        }
        guard let idMapper else { return (mutationTrack, mutationTrack.id) }
        guard let writeID = await idMapper.appleScriptID(forMusicKitID: mutationTrack.id) else {
            throw UndoCoordinatorError.missingAppleScriptID(trackID: mutationTrack.id)
        }
        return (mutationTrack, writeID)
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
        effect: String = "backup recovery checkpoint"
    ) throws -> (
        entry: ChangeLogEntry,
        metadata: (phase: BackupRestorePhase, historyEntryID: UUID?, originYear: Int?)
    )? {
        struct Payload: Codable {
            let entry: ChangeLogEntry
            let phase: BackupRestorePhase
            let historyEntryID: UUID?
            let recoveryOriginYear: Int?
        }

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
                let payload = Payload(
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
            let payload = try decoder.decode(Payload.self, from: Data(contentsOf: backupCheckpointURL))
            if let targetYear {
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
            return (payload.entry, (payload.phase, payload.historyEntryID, payload.recoveryOriginYear))
        } catch let error as UpdateCoordinatorError {
            throw error
        } catch {
            throw UpdateCoordinatorError.writeFinalizationFailed(trackID: trackID, effects: [effect])
        }
    }

    static func publicFailureDescription(for error: Error) -> String {
        if let undoError = error as? UndoCoordinatorError {
            switch undoError {
            case let .revertFailed(_, reason):
                return reason == "AppleScript write failed" ? reason : "Failed to revert track"
            case .noChangesToRevert, .invalidBackupCSV, .missingAppleScriptID, .historyStoreUnavailable:
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
