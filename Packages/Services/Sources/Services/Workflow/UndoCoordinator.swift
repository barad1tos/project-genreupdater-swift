import Core
import Foundation
import OSLog

// MARK: - Undo Coordinator

/// Reverts metadata changes by writing back old values via AppleScript.
///
/// Records every change made by `UpdateCoordinator`, enabling individual,
/// batch, and selective undo operations. History persists to SwiftData,
/// surviving app relaunches.
///
/// Undo is a FREE feature — no tier gating required.
public actor UndoCoordinator {
    private let scriptBridge: any AppleScriptClient
    private let idMapper: (any TrackIDMapping)?
    private let changeLogStore: (any ChangeLogStore)?
    private let trackStore: (any TrackStateStore)?
    private let cache: (any CacheService)?
    private var librarySnapshotService: (any LibrarySnapshotService)?
    private var cleaning: CleaningConfig?
    private var history: [ChangeLogEntry]
    private let legacyHistoryURL: URL
    private let backupCheckpointURL: URL
    private let fileManager: FileManager
    private let log = Logger(subsystem: "com.genreupdater", category: "UndoCoordinator")
    private var hasLoadedHistory = false

    public init(
        scriptBridge: any AppleScriptClient,
        idMapper: (any TrackIDMapping)? = nil,
        stores: Stores,
        librarySnapshotService: (any LibrarySnapshotService)? = nil,
        cleaning: CleaningConfig? = nil,
        directory: URL? = nil
    ) {
        self.scriptBridge = scriptBridge
        self.idMapper = idMapper
        self.changeLogStore = stores.changeLog
        self.trackStore = stores.tracks
        self.cache = stores.cache
        self.librarySnapshotService = librarySnapshotService
        self.cleaning = cleaning
        self.fileManager = .default
        let base = directory ?? Self.defaultDirectory()
        let historyURL = base.appendingPathComponent("undo-history.json")
        self.legacyHistoryURL = historyURL
        self.backupCheckpointURL = base.appendingPathComponent("pending-year-revert.json")
        self.history = []
    }

    public init(
        scriptBridge: any AppleScriptClient,
        idMapper: (any TrackIDMapping)? = nil,
        changeLogStore: (any ChangeLogStore)? = nil,
        cache: (any CacheService)? = nil,
        librarySnapshotService: (any LibrarySnapshotService)? = nil,
        cleaning: CleaningConfig? = nil,
        directory: URL? = nil
    ) {
        self.init(
            scriptBridge: scriptBridge,
            idMapper: idMapper,
            stores: Stores(changeLog: changeLogStore, cache: cache),
            librarySnapshotService: librarySnapshotService,
            cleaning: cleaning,
            directory: directory
        )
    }

    public func initialize() async {
        await loadHistoryIfNeeded()
    }

    public func updateRuntimeDependencies(
        librarySnapshotService: (any LibrarySnapshotService)?,
        cleaning: CleaningConfig? = nil
    ) {
        self.librarySnapshotService = librarySnapshotService
        self.cleaning = cleaning
    }

    // MARK: Record

    /// Log a change after a successful write to Music.app.
    public func recordChange(_ entry: ChangeLogEntry) async throws {
        await loadHistoryIfNeeded()

        history.append(entry)
        try await changeLogStore?.saveEntry(entry)
        log
            .info(
                "Recorded \(entry.changeType.rawValue, privacy: .public) for track \(entry.trackID, privacy: .private)"
            )
    }

    /// Record multiple changes at once (e.g. after batch processing).
    public func recordChanges(_ entries: [ChangeLogEntry]) async throws {
        await loadHistoryIfNeeded()

        history.append(contentsOf: entries)
        try await changeLogStore?.saveEntries(entries)
        log.info("Recorded \(entries.count, privacy: .public) change(s)")
    }

    /// Records repaired evidence durable-first, replacing same-ID in-memory
    /// entries only after the store accepts them. The normal `recordChange`
    /// and `recordChanges` paths deliberately retain in-memory undo when
    /// persistence fails mid-run.
    public func recordRepairedChanges(_ entries: [ChangeLogEntry]) async throws {
        await loadHistoryIfNeeded()

        try await changeLogStore?.saveEntries(entries)
        let repairedIDs = Set(entries.map(\.id))
        history.removeAll { repairedIDs.contains($0.id) }
        history.append(contentsOf: entries)
        let noun = entries.count == 1 ? "entry" : "entries"
        log.info("Repaired \(entries.count, privacy: .public) change history \(noun, privacy: .public)")
    }

    // MARK: Revert Single

    /// Revert a single change by writing the old value back to Music.app.
    public func revertChange(_ entry: ChangeLogEntry) async throws {
        await loadHistoryIfNeeded()

        let context = revertContext(for: entry)
        let oldValue: (property: String, value: String, recoveryOrigin: String?)? = switch entry.changeType {
        case .genreUpdate:
            entry.oldGenre.map { ("genre", $0, nil) }
        case .yearUpdate, .yearRevert:
            entry.oldYear.map { ("year", String($0), context.oldestEntry?.oldYear.map(String.init)) }
        case .trackCleaning:
            entry.oldTrackName.map { ("name", $0, nil) }
        case .albumCleaning:
            entry.oldAlbumName.map { ("album", $0, context.oldestEntry?.oldAlbumName) }
        case .artistRename:
            entry.oldArtist.map { ("artist", $0, context.oldestEntry?.oldArtist) }
        }

        guard let oldValue else {
            log.warning(
                "Cannot revert \(entry.changeType.rawValue, privacy: .public) for track \(entry.trackID, privacy: .private): no old value stored"
            )
            await removeFromHistory(entry)
            return
        }

        _ = try await performRevertWrite(
            change: context.change,
            property: oldValue.property,
            value: oldValue.value,
            recoveryOrigin: oldValue.recoveryOrigin ?? oldValue.value
        )

        await removeFromHistory(entry)
        log
            .info(
                "Reverted \(entry.changeType.rawValue, privacy: .public) for track \(entry.trackID, privacy: .private)"
            )
    }

    // MARK: Revert Batch

    /// Revert all provided changes in reverse chronological order.
    public func revertBatch(_ entries: [ChangeLogEntry]) async throws {
        guard !entries.isEmpty else {
            throw UndoCoordinatorError.noChangesToRevert
        }

        let sorted = entries.sorted { $0.timestamp > $1.timestamp }
        var succeeded = 0
        var errorDescriptions: [String] = []

        for entry in sorted {
            do {
                try await revertChange(entry)
                succeeded += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AppleScriptOutcomeError {
                throw error
            } catch let error as UpdateCoordinatorError {
                throw error
            } catch {
                let failureDescription = Self.publicFailureDescription(for: error)
                errorDescriptions.append(failureDescription)
                log
                    .error(
                        "Failed to revert \(entry.changeType.rawValue, privacy: .public) for track \(entry.trackID, privacy: .private): \(failureDescription, privacy: .public)"
                    )
            }
        }

        if !errorDescriptions.isEmpty {
            throw UndoCoordinatorError.partialRevertFailure(
                succeeded: succeeded,
                failed: errorDescriptions.count,
                errorDescriptions: errorDescriptions
            )
        }
    }

    /// Revert only the provided entries (user-selected subset).
    public func revertSelective(_ entries: [ChangeLogEntry]) async throws {
        try await revertBatch(entries)
    }

    /// Restore years from a Python-compatible backup track list CSV.
    public func revertYearsFromBackupCSV(
        _ csv: String,
        artist: String,
        album: String? = nil,
        currentTracks: [Track]
    ) async throws -> YearBackupRevertResult {
        let targets = try YearBackupCSVParser.parse(
            csv,
            artist: artist,
            album: album
        )
        guard !targets.isEmpty else {
            throw UndoCoordinatorError.noChangesToRevert
        }
        return try await revertYearBackupTargets(
            targets,
            currentTracks: currentTracks
        )
    }

    // MARK: History

    /// Get change history, optionally limited to most recent N entries.
    public func getHistory(limit: Int? = nil) async -> [ChangeLogEntry] {
        await loadHistoryIfNeeded()

        let sorted = history.sorted { $0.timestamp > $1.timestamp }
        if let limit {
            return Array(sorted.prefix(limit))
        }
        return sorted
    }

    /// Reads store-backed history for recovery decisions, migrating legacy
    /// JSON into an empty store, then reconciles the in-memory view. Missing
    /// storage and read or migration failures propagate without reconciliation.
    public func loadDurableHistory() async throws -> [ChangeLogEntry] {
        guard changeLogStore != nil else {
            throw UndoCoordinatorError.historyStoreUnavailable
        }
        let durableHistory = try await loadHistoryFromStoreOrLegacy()
        history = durableHistory
        hasLoadedHistory = true
        return durableHistory.sorted { $0.timestamp > $1.timestamp }
    }

    /// Clear all history from memory and disk.
    public func clearHistory() async {
        await loadHistoryIfNeeded()

        let count = history.count
        history.removeAll()
        try? fileManager.removeItem(at: legacyHistoryURL)
        try? await changeLogStore?.deleteAll()
        log.info("Cleared \(count, privacy: .public) history entries")
    }

    // MARK: ID Resolution

    private func resolveWriteID(for trackID: String) async throws -> String {
        guard let idMapper else { return trackID }
        guard let appleScriptID = await idMapper.appleScriptID(forMusicKitID: trackID) else {
            throw UndoCoordinatorError.missingAppleScriptID(trackID: trackID)
        }
        return appleScriptID
    }

    private func mutationContext(for track: Track) async throws -> (track: Track, writeID: String) {
        let mutationTrack: Track
        if let idMapper {
            guard let enrichedTrack = await idMapper.trackWithAppleScriptMetadata(for: track) else {
                throw UndoCoordinatorError.missingAppleScriptID(trackID: track.id)
            }
            mutationTrack = enrichedTrack
        } else {
            mutationTrack = track
        }
        try validateWriteEligibility(for: mutationTrack)
        let writeID = try await resolveWriteID(for: mutationTrack.id)
        return (mutationTrack, writeID)
    }

    private func validateWriteEligibility(for track: Track) throws {
        guard track.canEdit else {
            throw UndoCoordinatorError.revertFailed(
                trackID: track.id,
                reason: UpdateCoordinatorError.trackNotEditable(trackID: track.id).localizedDescription
            )
        }
        guard UpdateCoordinator.isTrackAvailableForProcessing(track) else {
            throw UndoCoordinatorError.revertFailed(
                trackID: track.id,
                reason: UpdateCoordinatorError.trackNotProcessable(
                    trackID: track.id,
                    status: track.trackStatus ?? "unknown"
                ).localizedDescription
            )
        }
    }

    private func performRevertWrite(
        change: ProposedChange,
        property: String,
        value: String,
        recoveryOrigin: String? = nil,
        prepareWrite: ((ProposedChange) async throws -> Void)? = nil,
        prepareDispatch: ((ProposedChange) async throws -> Void)? = nil,
        restorePreparedWrite: ((ProposedChange) async throws -> Void)? = nil,
        prepareMirror: ((ProposedChange, AppleScriptWriteResult) async throws -> Void)? = nil
    ) async throws -> AppleScriptWriteResult {
        let mutation = try await mutationContext(for: change.track)
        let mutationChange = ProposedChange(
            id: change.id,
            track: mutation.track,
            changeType: change.changeType,
            oldValue: change.oldValue,
            newValue: change.newValue,
            confidence: change.confidence,
            source: change.source,
            isAccepted: change.isAccepted
        )

        do {
            try await prepareWrite?(mutationChange)
            try await prepareDispatch?(mutationChange)
            let attemptState = WriteAttemptState()
            let result: AppleScriptWriteResult
            do {
                result = try await scriptBridge.updateTrackProperty(
                    trackID: mutation.writeID,
                    property: property,
                    value: value,
                    onAttempt: { attemptState.markAttempted() }
                )
            } catch {
                if !attemptState.hasAttempted {
                    try await restorePreparedWrite?(mutationChange)
                }
                throw error
            }
            do {
                try await prepareMirror?(mutationChange, result)
                let entry = UpdateCoordinator.changeToLogEntry(mutationChange, recoveryOrigin: recoveryOrigin)
                try await trackStore?.persistAppliedChange(entry)
            } catch {
                await invalidateCaches(for: mutationChange)
                if let error = error as? UpdateCoordinatorError {
                    throw error
                }
                throw UpdateCoordinatorError.writeFinalizationFailed(
                    trackID: change.track.id,
                    effects: ["track mirror"]
                )
            }
            await invalidateCaches(for: mutationChange)
            return result
        } catch {
            switch error {
            case is CancellationError, is UndoCoordinatorError, is UpdateCoordinatorError, is AppleScriptBridgeError:
                throw error
            case is AppleScriptOutcomeError:
                await invalidateCaches(for: mutationChange)
                throw error
            default:
                throw UndoCoordinatorError.revertFailed(
                    trackID: change.track.id,
                    reason: "AppleScript write failed"
                )
            }
        }
    }

    private func invalidateCaches(for change: ProposedChange) async {
        if let cache {
            for target in UpdateCoordinator.cacheInvalidationTargets(for: change, cleaning: cleaning) {
                await cache.invalidateAlbum(artist: target.artist, album: target.album)
                await cache.invalidateCachedAPIResults(artist: target.artist, album: target.album)
            }
        }
        await librarySnapshotService?.clearSnapshot()
    }

    private func revertContext(for entry: ChangeLogEntry) -> (change: ProposedChange, oldestEntry: ChangeLogEntry?) {
        let track = Track(
            id: entry.trackID,
            name: entry.newTrackName ?? entry.trackName,
            artist: entry.newArtist ?? entry.artist,
            album: entry.newAlbumName ?? entry.albumName,
            genre: entry.newGenre,
            year: entry.newYear
        )
        let values: (oldValue: String?, newValue: String?) = switch entry.changeType {
        case .genreUpdate:
            (entry.oldGenre, entry.newGenre)
        case .yearUpdate, .yearRevert:
            (entry.oldYear.map(String.init), entry.newYear.map(String.init))
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
            source: "undo"
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

    // MARK: Backup CSV Revert

    private func revertYearBackupTargets(
        _ targets: [YearBackupRevertTarget],
        currentTracks: [Track]
    ) async throws -> YearBackupRevertResult {
        let matcher = YearBackupTrackMatcher(currentTracks: currentTracks)
        var updatedCount = 0
        var skippedCount = 0
        var missingCount = 0
        var failedCount = 0
        var firstFailureDescription: String?

        for target in targets {
            guard let track = matcher.findTrack(for: target) else {
                missingCount += 1
                continue
            }

            do {
                let result = try await finishBackupWrite(track, targetYear: target.year)
                if result == .changed {
                    updatedCount += 1
                } else {
                    skippedCount += 1
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AppleScriptOutcomeError {
                throw error
            } catch let error as UpdateCoordinatorError {
                throw error
            } catch {
                if fileManager.fileExists(atPath: backupCheckpointURL.path) {
                    throw UpdateCoordinatorError.writeFinalizationFailed(
                        trackID: track.id,
                        effects: ["backup recovery checkpoint"]
                    )
                }
                failedCount += 1
                let failureDescription = Self.publicFailureDescription(for: error)
                firstFailureDescription = firstFailureDescription ?? failureDescription
                log.error(
                    "Failed to restore backup year for track \(track.id, privacy: .private): \(failureDescription, privacy: .public)"
                )
            }
        }

        return YearBackupRevertResult(
            parsedCount: targets.count,
            updatedCount: updatedCount,
            skippedCount: skippedCount,
            missingCount: missingCount,
            failedCount: failedCount,
            firstFailureDescription: firstFailureDescription
        )
    }

    private func finishBackupWrite(
        _ track: Track,
        targetYear: Int
    ) async throws -> AppleScriptWriteResult {
        let pendingCheckpoint = try backupCheckpoint(
            for: track.id,
            targetYear: targetYear,
            observedYear: track.year
        )
        let mirrorTrack = try await trackStore?.getTrack(byID: track.id)
        let change = ProposedChange(
            track: track,
            changeType: .yearRevert,
            oldValue: (mirrorTrack?.year ?? track.year).map(String.init),
            newValue: String(targetYear),
            confidence: 100,
            source: "backup_csv"
        )
        if let pendingCheckpoint {
            switch pendingCheckpoint.phase {
            case .prepared: break
            case .dispatchedUnknown:
                throw UpdateCoordinatorError.writeFinalizationFailed(
                    trackID: change.track.id,
                    effects: ["ambiguous backup write outcome"]
                )
            case .changed, .noChange:
                let result: AppleScriptWriteResult = pendingCheckpoint.phase == .changed ? .changed : .noChange
                try await finalizeBackupCheckpoint(
                    pendingCheckpoint,
                    change: change,
                    result: result,
                    completesRecovery: true
                )
                return result
            }
        }
        let result = try await performRevertWrite(
            change: change,
            property: "year",
            value: String(targetYear),
            recoveryOrigin: String(targetYear),
            prepareWrite: { [self] change in
                guard pendingCheckpoint == nil else { return }
                let entry = UpdateCoordinator.changeToLogEntry(change)
                _ = try backupCheckpoint(for: entry.trackID, writing: (entry, .prepared))
            },
            prepareDispatch: { [self] change in
                guard pendingCheckpoint == nil || pendingCheckpoint?.phase == .prepared else { return }
                let entry = pendingCheckpoint?.entry ?? UpdateCoordinator.changeToLogEntry(change)
                _ = try backupCheckpoint(for: entry.trackID, writing: (entry, .dispatchedUnknown))
            },
            restorePreparedWrite: { [self] change in
                guard pendingCheckpoint == nil || pendingCheckpoint?.phase == .prepared else { return }
                let entry = pendingCheckpoint?.entry ?? UpdateCoordinator.changeToLogEntry(change)
                _ = try backupCheckpoint(for: entry.trackID, writing: (entry, .prepared))
            },
            prepareMirror: { [self] change, result in
                try await finalizeBackupCheckpoint(pendingCheckpoint, change: change, result: result)
            }
        )
        _ = try backupCheckpoint(for: track.id, shouldRemove: true)
        return result
    }

    private func backupCheckpoint(
        for trackID: String,
        targetYear: Int? = nil,
        observedYear: Int? = nil,
        writing checkpoint: (entry: ChangeLogEntry, phase: BackupRestorePhase)? = nil,
        shouldRemove: Bool = false
    ) throws -> (entry: ChangeLogEntry, phase: BackupRestorePhase)? {
        struct Payload: Codable {
            let entry: ChangeLogEntry
            let phase: BackupRestorePhase
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
                    at: backupCheckpointURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(Payload(entry: checkpoint.entry, phase: checkpoint.phase))
                    .write(to: backupCheckpointURL, options: .atomic)
                return checkpoint
            }
            let data = try Data(contentsOf: backupCheckpointURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(Payload.self, from: data)
            if let targetYear {
                guard payload.entry.changeType == .yearRevert,
                      payload.entry.trackID == trackID,
                      payload.entry.newYear == targetYear
                else {
                    throw UpdateCoordinatorError.writeFinalizationFailed(
                        trackID: payload.entry.trackID,
                        effects: ["prior backup recovery checkpoint"]
                    )
                }
                guard payload.phase != .dispatchedUnknown else {
                    throw UpdateCoordinatorError.writeFinalizationFailed(
                        trackID: trackID,
                        effects: ["ambiguous backup write outcome"]
                    )
                }
                let expectedYear = payload.phase == .prepared ? payload.entry.oldYear : targetYear
                guard observedYear == expectedYear else {
                    throw UpdateCoordinatorError.writeFinalizationFailed(
                        trackID: trackID,
                        effects: ["stale backup recovery checkpoint"]
                    )
                }
            }
            return (payload.entry, payload.phase)
        } catch let error as UpdateCoordinatorError {
            throw error
        } catch {
            throw UpdateCoordinatorError.writeFinalizationFailed(
                trackID: trackID,
                effects: ["backup recovery checkpoint"]
            )
        }
    }

    private func finalizeBackupCheckpoint(
        _ pendingCheckpoint: (entry: ChangeLogEntry, phase: BackupRestorePhase)?,
        change: ProposedChange,
        result: AppleScriptWriteResult,
        completesRecovery: Bool = false
    ) async throws {
        guard var checkpoint = try pendingCheckpoint ?? backupCheckpoint(for: change.track.id) else {
            throw UpdateCoordinatorError.writeFinalizationFailed(
                trackID: change.track.id,
                effects: ["backup recovery checkpoint"]
            )
        }
        checkpoint.phase = switch pendingCheckpoint?.phase {
        case .changed: .changed
        case .noChange: .noChange
        case .prepared, .dispatchedUnknown, nil:
            result == .changed ? .changed : .noChange
        }
        _ = try backupCheckpoint(for: checkpoint.entry.trackID, writing: checkpoint)
        if checkpoint.phase == .changed {
            do {
                await loadHistoryIfNeeded()
                if pendingCheckpoint == nil || !history.contains(where: { $0.id == checkpoint.entry.id }) {
                    try await recordRepairedChanges([checkpoint.entry])
                }
            } catch {
                log.error("""
                Failed to persist year revert history for track \(checkpoint.entry.trackID, privacy: .private): \
                \(error.localizedDescription, privacy: .private)
                """)
                throw UpdateCoordinatorError.writeFinalizationFailed(
                    trackID: checkpoint.entry.trackID,
                    effects: ["change history"]
                )
            }
        }
        guard completesRecovery else { return }

        do {
            var mirrorEntry = checkpoint.entry
            mirrorEntry.oldYear = mirrorEntry.newYear
            try await trackStore?.persistAppliedChange(mirrorEntry)
        } catch {
            await invalidateCaches(for: change)
            throw UpdateCoordinatorError.writeFinalizationFailed(
                trackID: change.track.id,
                effects: ["track mirror"]
            )
        }
        await invalidateCaches(for: change)
        _ = try backupCheckpoint(for: change.track.id, shouldRemove: true)
    }

    private static func publicFailureDescription(for error: Error) -> String {
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
            return publicAppleScriptFailureDescription(for: appleScriptError)
        }
        if let outcomeError = error as? AppleScriptOutcomeError {
            return outcomeError.localizedDescription
        }
        return "AppleScript write failed"
    }

    private static func publicAppleScriptFailureDescription(for error: AppleScriptBridgeError) -> String {
        switch error {
        case .dispatchDeadline,
             .invalidLibraryPath,
             .libraryChanged,
             .scriptNotFound,
             .scriptsNotInstalled,
             .musicAppNotRunning,
             .timeout:
            error.errorDescription ?? "AppleScript write failed"
        case .executionFailed:
            "AppleScript write failed"
        case .parseError:
            "AppleScript output could not be parsed"
        }
    }

    // MARK: Persistence

    private func removeFromHistory(_ entry: ChangeLogEntry) async {
        await loadHistoryIfNeeded()

        history.removeAll { $0.id == entry.id }
        try? await changeLogStore?.delete(entryID: entry.id)
    }

    private func loadHistoryIfNeeded() async {
        guard !hasLoadedHistory else { return }

        do {
            history = try await loadHistoryFromStoreOrLegacy()
        } catch {
            history = Self.loadPersistedHistory(from: legacyHistoryURL)
            log.warning("Failed to load SwiftData undo history: \(error.localizedDescription, privacy: .public)")
        }
        hasLoadedHistory = true
    }

    private func loadHistoryFromStoreOrLegacy() async throws -> [ChangeLogEntry] {
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

    private static func loadPersistedHistory(from url: URL) -> [ChangeLogEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ChangeLogEntry].self, from: data)) ?? []
    }

    private static func defaultDirectory() -> URL {
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
