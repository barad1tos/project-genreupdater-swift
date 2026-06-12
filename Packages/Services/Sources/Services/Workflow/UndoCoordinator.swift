import Core
import Foundation
import OSLog

// MARK: - Undo Error

public enum UndoCoordinatorError: Error, LocalizedError {
    case revertFailed(trackID: String, reason: String)
    case noChangesToRevert
    case partialRevertFailure(succeeded: Int, failed: Int, errorDescriptions: [String])

    public var errorDescription: String? {
        switch self {
        case let .revertFailed(trackID, reason):
            "Failed to revert track \(trackID): \(reason)"
        case .noChangesToRevert:
            "No changes available to revert"
        case let .partialRevertFailure(succeeded, failed, _):
            "Partial revert: \(succeeded) succeeded, \(failed) failed"
        }
    }
}

// MARK: - Undo Coordinator

/// Reverts metadata changes by writing back old values via AppleScript.
///
/// Records every change made by `UpdateCoordinator`, enabling individual,
/// batch, and selective undo operations. History persists to JSON in
/// Application Support, surviving app relaunches.
///
/// Undo is a FREE feature — no tier gating required.
public actor UndoCoordinator {
    private let scriptBridge: any AppleScriptClient
    private let idMapper: (any TrackIDMapping)?
    private let changeLogStore: (any ChangeLogStore)?
    private var history: [ChangeLogEntry]
    private let historyURL: URL
    private let fileManager: FileManager
    private let log = Logger(subsystem: "com.genreupdater", category: "UndoCoordinator")

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

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
        self.historyURL = historyURL
        self.history = Self.loadPersistedHistory(from: historyURL)
    }

    // MARK: Record

    /// Log a change after a successful write to Music.app.
    public func recordChange(_ entry: ChangeLogEntry) async {
        history.append(entry)
        try? saveHistory()
        try? await changeLogStore?.saveEntry(entry)
        log
            .info(
                "Recorded \(entry.changeType.rawValue, privacy: .public) for track \(entry.trackID, privacy: .private)"
            )
    }

    /// Record multiple changes at once (e.g. after batch processing).
    public func recordChanges(_ entries: [ChangeLogEntry]) async {
        history.append(contentsOf: entries)
        try? saveHistory()
        try? await changeLogStore?.saveEntries(entries)
        log.info("Recorded \(entries.count, privacy: .public) change(s)")
    }

    // MARK: Revert Single

    /// Revert a single change by writing the old value back to Music.app.
    public func revertChange(_ entry: ChangeLogEntry) async throws {
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

        let writeID = await resolveWriteID(for: entry.trackID)

        try await scriptBridge.updateTrackProperty(
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
                errorDescriptions.append(error.localizedDescription)
                log
                    .error(
                        "Failed to revert \(entry.changeType.rawValue, privacy: .public) for track \(entry.trackID, privacy: .private): \(error.localizedDescription, privacy: .public)"
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

    // MARK: History

    /// Get change history, optionally limited to most recent N entries.
    public func getHistory(limit: Int? = nil) -> [ChangeLogEntry] {
        let sorted = history.sorted { $0.timestamp > $1.timestamp }
        if let limit {
            return Array(sorted.prefix(limit))
        }
        return sorted
    }

    /// Clear all history from memory and disk.
    public func clearHistory() async {
        let count = history.count
        history.removeAll()
        try? fileManager.removeItem(at: historyURL)
        try? await changeLogStore?.deleteAll()
        log.info("Cleared \(count, privacy: .public) history entries")
    }

    // MARK: ID Resolution

    private func resolveWriteID(for trackID: String) async -> String {
        guard let idMapper else { return trackID }
        return await idMapper.appleScriptID(forMusicKitID: trackID) ?? trackID
    }

    // MARK: Persistence

    private func removeFromHistory(_ entry: ChangeLogEntry) async {
        history.removeAll { $0.id == entry.id }
        try? saveHistory()
        try? await changeLogStore?.delete(entryID: entry.id)
    }

    private func saveHistory() throws {
        try ensureDirectoryExists()
        let data = try encoder.encode(history)
        try data.write(to: historyURL, options: .atomic)
    }

    private static func loadPersistedHistory(from url: URL) -> [ChangeLogEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ChangeLogEntry].self, from: data)) ?? []
    }

    private func ensureDirectoryExists() throws {
        let directory = historyURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
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
