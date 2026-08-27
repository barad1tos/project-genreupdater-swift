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
    let musicApp: any MusicAppMutating & MusicAppVerifying
    let idMapper: (any TrackIDMapping)?
    let changeLogStore: (any ChangeLogStore)?
    let trackStore: (any TrackStateStore)?
    let cache: (any CacheService)?
    var librarySnapshotService: (any LibrarySnapshotService)?
    var cleaning: CleaningConfig?
    var history: [ChangeLogEntry]
    let legacyHistoryURL: URL
    let backupCheckpointURL: URL
    let fileManager: FileManager
    private let log = Logger(subsystem: "com.genreupdater", category: "UndoCoordinator")
    private var hasLoadedHistory = false

    public init(
        musicApp: any MusicAppMutating & MusicAppVerifying,
        idMapper: (any TrackIDMapping)? = nil,
        stores: Stores,
        librarySnapshotService: (any LibrarySnapshotService)? = nil,
        cleaning: CleaningConfig? = nil,
        directory: URL? = nil
    ) {
        self.musicApp = musicApp
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
        musicApp: any MusicAppMutating & MusicAppVerifying,
        idMapper: (any TrackIDMapping)? = nil,
        changeLogStore: (any ChangeLogStore)? = nil,
        cache: (any CacheService)? = nil,
        librarySnapshotService: (any LibrarySnapshotService)? = nil,
        cleaning: CleaningConfig? = nil,
        directory: URL? = nil
    ) {
        self.init(
            musicApp: musicApp,
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
        if entry.changeType == .yearUpdate || entry.changeType == .yearRevert {
            try await revertYearChange(entry, context: context)
            return
        }
        let oldValue: (property: MusicTrackProperty, value: String, recoveryOrigin: String?)? = switch entry
            .changeType {
        case .genreUpdate:
            entry.oldGenre.map { (.genre, $0, nil) }
        case .yearUpdate, .yearRevert:
            nil
        case .trackCleaning:
            entry.oldTrackName.map { (.name, $0, nil) }
        case .albumCleaning:
            entry.oldAlbumName.map { (.album, $0, context.oldestEntry?.oldAlbumName) }
        case .artistRename:
            entry.oldArtist.map { (.artist, $0, context.oldestEntry?.oldArtist) }
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

    private func revertYearChange(
        _ historyEntry: ChangeLogEntry,
        context: (change: ProposedChange, oldestEntry: ChangeLogEntry?)
    ) async throws {
        let targetYear = historyEntry.oldYear ?? MusicAppYear.missingValue
        let change = yearRevertChange(for: historyEntry, context: context, targetYear: targetYear)
        let pending = try backupCheckpoint(
            for: historyEntry.trackID,
            purpose: .historyUndo,
            effect: "undo recovery checkpoint"
        )
        let recoveryOriginYear = context.oldestEntry.map {
            $0.oldYear ?? MusicAppYear.missingValue
        } ?? targetYear
        if let pending, try await resumePendingYearUndo(
            pending,
            historyEntry: historyEntry,
            targetYear: targetYear,
            change: change
        ) {
            return
        }
        let saveCheckpoint: (BackupRestorePhase, PreparedWrite) throws -> Void = { [self] phase, write in
            let entry = UpdateCoordinator.changeToLogEntry(
                write.change,
                databaseID: write.databaseID
            )
            _ = try backupCheckpoint(
                for: historyEntry.trackID,
                writing: (entry, (phase, historyEntry.id, recoveryOriginYear)),
                purpose: .historyUndo,
                effect: "undo recovery checkpoint"
            )
        }
        let write = try await performRevertWrite(
            change: change,
            property: .year,
            value: String(targetYear),
            recoveryOrigin: String(recoveryOriginYear),
            attemptHooks: (
                prepareWrite: { preparedWrite in
                    guard pending == nil else { return }
                    try saveCheckpoint(.prepared, preparedWrite)
                },
                prepareDispatch: { preparedWrite in
                    try saveCheckpoint(.dispatchedUnknown, preparedWrite)
                },
                restorePreparedWrite: { preparedWrite in
                    try saveCheckpoint(.prepared, preparedWrite)
                }
            ),
            prepareMirror: { preparedWrite, result in
                let phase: BackupRestorePhase = result == .changed ? .changed : .noChange
                try saveCheckpoint(phase, preparedWrite)
            }
        )
        try await finishYearUndo(
            write.entry,
            historyEntryID: historyEntry.id,
            recoveryOriginYear: recoveryOriginYear,
            change: change,
            repairsMirror: false
        )
    }

    private func resumePendingYearUndo(
        _ checkpoint: (
            entry: ChangeLogEntry,
            metadata: (phase: BackupRestorePhase, historyEntryID: UUID?, originYear: Int?)
        ),
        historyEntry: ChangeLogEntry,
        targetYear: Int,
        change: ProposedChange
    ) async throws -> Bool {
        guard checkpoint.metadata.historyEntryID == historyEntry.id,
              checkpoint.entry.trackID == historyEntry.trackID,
              checkpoint.entry.newYear == targetYear
        else {
            throw UndoCoordinatorError.undoRecoveryConflict(trackID: historyEntry.trackID)
        }
        guard checkpoint.metadata.phase == .completed else {
            return try await resumeYearUndo(checkpoint, change: change)
        }
        try await finishYearUndo(
            checkpoint.entry,
            historyEntryID: historyEntry.id,
            recoveryOriginYear: checkpoint.metadata.originYear,
            change: change,
            repairsMirror: false
        )
        return true
    }

    private func resumeYearUndo(
        _ checkpoint: (
            entry: ChangeLogEntry,
            metadata: (phase: BackupRestorePhase, historyEntryID: UUID?, originYear: Int?)
        ),
        change: ProposedChange
    ) async throws -> Bool {
        let databaseID = try await recoveryDatabaseID(for: change.track.id)
        let tracks: [Track]
        do {
            tracks = try await musicApp.fetchMetadata(for: [databaseID])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.error(
                "Failed to observe undo outcome for track \(change.track.id, privacy: .private): \(error.localizedDescription, privacy: .private)"
            )
            throw UndoCoordinatorError.undoOutcomeUnknown(trackID: change.track.id)
        }
        guard let observed = tracks.first else {
            throw UndoCoordinatorError.undoOutcomeUnknown(trackID: change.track.id)
        }
        let property = MusicTrackProperty.year
        let observedValue = property.comparisonValue(property.currentValue(in: observed))
        if observedValue == property.comparisonValue(checkpoint.entry.newYear.map(String.init)) {
            try await finishYearUndo(
                checkpoint.entry,
                historyEntryID: checkpoint.metadata.historyEntryID,
                recoveryOriginYear: checkpoint.metadata.originYear,
                change: change,
                repairsMirror: true
            )
            return true
        }
        let sourceValue = property.comparisonValue(checkpoint.entry.oldYear.map(String.init))
        if observedValue == sourceValue, checkpoint.metadata.phase == .prepared {
            return false
        }
        if observedValue == sourceValue, checkpoint.metadata.phase == .dispatchedUnknown {
            _ = try backupCheckpoint(
                for: change.track.id,
                shouldRemove: true,
                purpose: .historyUndo,
                effect: "undo recovery checkpoint"
            )
            throw UndoCoordinatorError.undoWriteNotApplied(trackID: change.track.id)
        }
        throw UndoCoordinatorError.undoRecoveryConflict(trackID: change.track.id)
    }

    private func finishYearUndo(
        _ checkpointEntry: ChangeLogEntry,
        historyEntryID: UUID?,
        recoveryOriginYear: Int?,
        change: ProposedChange,
        repairsMirror: Bool
    ) async throws {
        if repairsMirror {
            do {
                var mirrorEntry = checkpointEntry
                mirrorEntry.oldYear = recoveryOriginYear ?? mirrorEntry.newYear
                try await trackStore?.persistAppliedChange(mirrorEntry)
            } catch {
                await invalidateCaches(for: change)
                throw UpdateCoordinatorError.writeFinalizationFailed(
                    trackID: change.track.id,
                    effects: ["track mirror"]
                )
            }
            await invalidateCaches(for: change)
        }
        _ = try backupCheckpoint(
            for: change.track.id,
            writing: (checkpointEntry, (.completed, historyEntryID, recoveryOriginYear)),
            purpose: .historyUndo,
            effect: "undo recovery checkpoint"
        )
        do {
            try await changeLogStore?.delete(entryID: historyEntryID ?? checkpointEntry.id)
        } catch {
            throw UpdateCoordinatorError.writeFinalizationFailed(
                trackID: change.track.id,
                effects: ["change history"]
            )
        }
        _ = try backupCheckpoint(
            for: change.track.id,
            shouldRemove: true,
            purpose: .historyUndo,
            effect: "undo recovery checkpoint"
        )
        history.removeAll { $0.id == historyEntryID }
        log.info("Reverted year metadata for track \(change.track.id, privacy: .private)")
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
            } catch let error as UndoCoordinatorError where error.blocksBatchRevert {
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
    ) async throws -> MusicWriteResult {
        let databaseID = try await mutationContext(for: track).databaseID
        let pendingCheckpoint = try backupCheckpoint(
            for: databaseID.rawValue,
            targetYear: targetYear,
            observedYear: track.year
        )
        let mirrorTrack = try await trackStore?.getHistoricalTrack(byID: databaseID.rawValue)
        let change = ProposedChange(
            track: track,
            changeType: .yearRevert,
            oldValue: (mirrorTrack?.year ?? track.year).map(String.init),
            newValue: String(targetYear),
            confidence: 100,
            source: "backup_csv"
        )
        if let resumed = try await resumeBackup(pendingCheckpoint, databaseID: databaseID, change: change) {
            return resumed
        }
        let write = try await performRevertWrite(
            change: change,
            property: .year,
            value: String(targetYear),
            recoveryOrigin: String(targetYear),
            attemptHooks: (
                prepareWrite: { [self] preparedWrite in
                    try saveBackupPhase(.prepared, for: preparedWrite, when: pendingCheckpoint == nil)
                },
                prepareDispatch: { [self] preparedWrite in
                    try saveBackupPhase(
                        .dispatchedUnknown,
                        for: preparedWrite,
                        when: pendingCheckpoint == nil || pendingCheckpoint?.metadata.phase == .prepared
                    )
                },
                restorePreparedWrite: { [self] preparedWrite in
                    try saveBackupPhase(
                        .prepared,
                        for: preparedWrite,
                        when: pendingCheckpoint == nil || pendingCheckpoint?.metadata.phase == .prepared
                    )
                }
            ),
            prepareMirror: { [self] preparedWrite, result in
                try await finalizeBackupCheckpoint(
                    pendingCheckpoint,
                    databaseID: preparedWrite.databaseID,
                    change: preparedWrite.change,
                    result: result
                )
            }
        )
        _ = try backupCheckpoint(for: databaseID.rawValue, shouldRemove: true)
        return write.result
    }

    private func resumeBackup(
        _ checkpoint: (
            entry: ChangeLogEntry,
            metadata: (phase: BackupRestorePhase, historyEntryID: UUID?, originYear: Int?)
        )?,
        databaseID: MusicDatabaseTrackID,
        change: ProposedChange
    ) async throws -> MusicWriteResult? {
        guard let checkpoint else { return nil }
        switch checkpoint.metadata.phase {
        case .prepared:
            return nil
        case .dispatchedUnknown:
            throw UpdateCoordinatorError.writeFinalizationFailed(
                trackID: databaseID.rawValue,
                effects: ["ambiguous backup write outcome"]
            )
        case .changed, .noChange, .completed:
            let result: MusicWriteResult = checkpoint.metadata.phase == .changed ? .changed : .noChange
            try await finalizeBackupCheckpoint(
                checkpoint,
                databaseID: databaseID,
                change: change,
                result: result,
                completesRecovery: true
            )
            return result
        }
    }

    private func saveBackupPhase(
        _ phase: BackupRestorePhase,
        for preparedWrite: PreparedWrite,
        when shouldSave: Bool
    ) throws {
        guard shouldSave else { return }
        let entry = UpdateCoordinator.changeToLogEntry(
            preparedWrite.change,
            databaseID: preparedWrite.databaseID
        )
        _ = try backupCheckpoint(for: entry.trackID, writing: (entry, (phase, nil, nil)))
    }

    private func finalizeBackupCheckpoint(
        _ pendingCheckpoint: (
            entry: ChangeLogEntry,
            metadata: (phase: BackupRestorePhase, historyEntryID: UUID?, originYear: Int?)
        )?,
        databaseID: MusicDatabaseTrackID,
        change: ProposedChange,
        result: MusicWriteResult,
        completesRecovery: Bool = false
    ) async throws {
        guard var checkpoint = try pendingCheckpoint ?? backupCheckpoint(for: databaseID.rawValue) else {
            throw UpdateCoordinatorError.writeFinalizationFailed(
                trackID: databaseID.rawValue,
                effects: ["backup recovery checkpoint"]
            )
        }
        checkpoint.metadata.phase = switch pendingCheckpoint?.metadata.phase {
        case .changed: .changed
        case .noChange: .noChange
        case .completed: .completed
        case .prepared, .dispatchedUnknown, nil:
            result == .changed ? .changed : .noChange
        }
        _ = try backupCheckpoint(for: checkpoint.entry.trackID, writing: checkpoint)
        if checkpoint.metadata.phase == .changed {
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
                trackID: databaseID.rawValue,
                effects: ["track mirror"]
            )
        }
        await invalidateCaches(for: change)
        _ = try backupCheckpoint(for: databaseID.rawValue, shouldRemove: true)
    }

    // MARK: Persistence

    private func removeFromHistory(_ entry: ChangeLogEntry) async {
        await loadHistoryIfNeeded()

        history.removeAll { $0.id == entry.id }
        try? await changeLogStore?.delete(entryID: entry.id)
    }

    private func loadHistoryIfNeeded() async {
        guard !hasLoadedHistory else { return }

        let didLoadHistory: Bool
        do {
            history = try await loadHistoryFromStoreOrLegacy()
            didLoadHistory = true
        } catch is CancellationError {
            return
        } catch {
            history = Self.loadPersistedHistory(from: legacyHistoryURL)
            didLoadHistory = false
            log.warning("Failed to load SwiftData undo history: \(error.localizedDescription, privacy: .public)")
        }
        if didLoadHistory {
            do {
                try await reconcileOrphanCheckpoint()
            } catch is CancellationError {
                return
            } catch {
                log.warning(
                    "Failed to clean completed undo recovery checkpoint: \(error.localizedDescription, privacy: .private)"
                )
            }
        }
        hasLoadedHistory = true
    }

    private func reconcileOrphanCheckpoint() async throws {
        guard let checkpoint = try backupCheckpoint(
            for: "pending-year-revert",
            purpose: .historyUndo,
            effect: "undo recovery checkpoint"
        ),
            let historyEntryID = checkpoint.metadata.historyEntryID,
            !history.contains(where: { $0.id == historyEntryID })
        else {
            return
        }
        switch checkpoint.metadata.phase {
        case .prepared, .dispatchedUnknown:
            return
        case .changed, .noChange:
            let entry = checkpoint.entry
            let track = Track(
                id: entry.trackID,
                name: entry.trackName,
                artist: entry.artist,
                album: entry.albumName,
                year: entry.oldYear
            )
            let change = ProposedChange(
                id: entry.id,
                track: track,
                changeType: .yearRevert,
                oldValue: entry.oldYear.map(String.init),
                newValue: entry.newYear.map(String.init),
                confidence: 100,
                source: "undo recovery"
            )
            _ = try await resumeYearUndo(checkpoint, change: change)
        case .completed:
            _ = try backupCheckpoint(
                for: checkpoint.entry.trackID,
                shouldRemove: true,
                purpose: .historyUndo,
                effect: "undo recovery checkpoint"
            )
        }
    }
}
