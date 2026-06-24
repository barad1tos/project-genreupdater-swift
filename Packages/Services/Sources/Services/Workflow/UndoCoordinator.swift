import Core
import Foundation
import OSLog

// MARK: - Undo Error

public enum UndoCoordinatorError: Error, LocalizedError {
    case revertFailed(trackID: String, reason: String)
    case noChangesToRevert
    case partialRevertFailure(succeeded: Int, failed: Int, errorDescriptions: [String])
    case invalidBackupCSV(reason: String)
    case missingAppleScriptID(trackID: String)

    public var errorDescription: String? {
        switch self {
        case let .revertFailed(trackID, reason):
            "Failed to revert track \(trackID): \(reason)"
        case .noChangesToRevert:
            "No changes available to revert"
        case let .partialRevertFailure(succeeded, failed, errorDescriptions):
            if let firstFailure = Self.firstFailureDescription(from: errorDescriptions) {
                "Partial revert: \(succeeded) succeeded, \(failed) failed. First failure: \(firstFailure)"
            } else {
                "Partial revert: \(succeeded) succeeded, \(failed) failed"
            }
        case let .invalidBackupCSV(reason):
            "Invalid backup CSV: \(reason)"
        case .missingAppleScriptID:
            "Missing AppleScript ID mapping for a track"
        }
    }

    private static func firstFailureDescription(from errorDescriptions: [String]) -> String? {
        errorDescriptions.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// Summary of a backup CSV year revert operation.
public struct YearBackupRevertResult: Sendable, Equatable {
    public let parsedCount: Int
    public let updatedCount: Int
    public let missingCount: Int

    public init(
        parsedCount: Int,
        updatedCount: Int,
        missingCount: Int
    ) {
        self.parsedCount = parsedCount
        self.updatedCount = updatedCount
        self.missingCount = missingCount
    }
}

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
    private var history: [ChangeLogEntry]
    private let legacyHistoryURL: URL
    private let fileManager: FileManager
    private let log = Logger(subsystem: "com.genreupdater", category: "UndoCoordinator")
    private var hasLoadedHistory = false

    public init(
        scriptBridge: any AppleScriptClient,
        idMapper: (any TrackIDMapping)? = nil,
        changeLogStore: (any ChangeLogStore)? = nil,
        directory: URL? = nil
    ) {
        self.scriptBridge = scriptBridge
        self.idMapper = idMapper
        self.changeLogStore = changeLogStore
        self.fileManager = .default
        let base = directory ?? Self.defaultDirectory()
        let historyURL = base.appendingPathComponent("undo-history.json")
        self.legacyHistoryURL = historyURL
        self.history = []
    }

    public func initialize() async {
        await loadHistoryIfNeeded()
    }

    // MARK: Record

    /// Log a change after a successful write to Music.app.
    public func recordChange(_ entry: ChangeLogEntry) async {
        await loadHistoryIfNeeded()

        history.append(entry)
        try? await changeLogStore?.saveEntry(entry)
        log
            .info(
                "Recorded \(entry.changeType.rawValue, privacy: .public) for track \(entry.trackID, privacy: .private)"
            )
    }

    /// Record multiple changes at once (e.g. after batch processing).
    public func recordChanges(_ entries: [ChangeLogEntry]) async {
        await loadHistoryIfNeeded()

        history.append(contentsOf: entries)
        try? await changeLogStore?.saveEntries(entries)
        log.info("Recorded \(entries.count, privacy: .public) change(s)")
    }

    // MARK: Revert Single

    /// Revert a single change by writing the old value back to Music.app.
    public func revertChange(_ entry: ChangeLogEntry) async throws {
        await loadHistoryIfNeeded()

        let oldValue: (property: String, value: String)? = switch entry.changeType {
        case .genreUpdate:
            entry.oldGenre.map { ("genre", $0) }
        case .yearUpdate, .yearRevert:
            entry.oldYear.map { ("year", String($0)) }
        case .trackCleaning:
            entry.oldTrackName.map { ("name", $0) }
        case .albumCleaning:
            entry.oldAlbumName.map { ("album", $0) }
        case .artistRename:
            entry.oldArtist.map { ("artist", $0) }
        }

        guard let oldValue else {
            log.warning(
                "Cannot revert \(entry.changeType.rawValue, privacy: .public) for track \(entry.trackID, privacy: .private): no old value stored"
            )
            await removeFromHistory(entry)
            return
        }

        let writeID = try await resolveWriteID(for: entry.trackID)

        _ = try await scriptBridge.updateTrackProperty(
            trackID: writeID,
            property: oldValue.property,
            value: oldValue.value
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

    // MARK: Backup CSV Revert

    private func revertYearBackupTargets(
        _ targets: [YearBackupRevertTarget],
        currentTracks: [Track]
    ) async throws -> YearBackupRevertResult {
        let matcher = YearBackupTrackMatcher(currentTracks: currentTracks)
        var updatedCount = 0
        var missingCount = 0
        var errorDescriptions: [String] = []

        for target in targets {
            guard let track = matcher.findTrack(for: target) else {
                missingCount += 1
                continue
            }

            do {
                let writeID = try await resolveWriteID(for: track.id)
                _ = try await scriptBridge.updateTrackProperty(
                    trackID: writeID,
                    property: "year",
                    value: String(target.year)
                )

                var entry = ChangeLogEntry(
                    changeType: .yearRevert,
                    trackID: track.id,
                    artist: track.artist,
                    trackName: track.name,
                    albumName: track.album
                )
                entry.oldYear = track.year
                entry.newYear = target.year
                await recordChange(entry)
                updatedCount += 1
            } catch {
                let failureDescription = Self.publicFailureDescription(for: error)
                errorDescriptions.append(failureDescription)
                log.error(
                    "Failed to restore backup year for track \(track.id, privacy: .private): \(failureDescription, privacy: .public)"
                )
            }
        }

        if !errorDescriptions.isEmpty {
            throw UndoCoordinatorError.partialRevertFailure(
                succeeded: updatedCount,
                failed: errorDescriptions.count,
                errorDescriptions: errorDescriptions
            )
        }

        return YearBackupRevertResult(
            parsedCount: targets.count,
            updatedCount: updatedCount,
            missingCount: missingCount
        )
    }

    private static func publicFailureDescription(for error: Error) -> String {
        if let undoError = error as? UndoCoordinatorError {
            return publicUndoFailureDescription(for: undoError)
        }
        if let appleScriptError = error as? AppleScriptBridgeError {
            return publicAppleScriptFailureDescription(for: appleScriptError)
        }
        return "AppleScript write failed"
    }

    private static func publicUndoFailureDescription(for error: UndoCoordinatorError) -> String {
        switch error {
        case .revertFailed:
            "Failed to revert track"
        case .noChangesToRevert, .invalidBackupCSV, .missingAppleScriptID:
            error.errorDescription ?? "Undo operation failed"
        case let .partialRevertFailure(succeeded, failed, _):
            "Partial revert: \(succeeded) succeeded, \(failed) failed"
        }
    }

    private static func publicAppleScriptFailureDescription(for error: AppleScriptBridgeError) -> String {
        switch error {
        case .scriptNotFound, .scriptsNotInstalled, .musicAppNotRunning, .timeout:
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
