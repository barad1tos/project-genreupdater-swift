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
/// batch, and selective undo operations. History persists in-memory
/// for the session; long-term persistence is handled by `TrackStateStore`.
///
/// Undo is a FREE feature — no tier gating required.
public actor UndoCoordinator {
    private let scriptBridge: any AppleScriptClient
    private var history: [ChangeLogEntry] = []
    private let log = Logger(subsystem: "com.genreupdater", category: "UndoCoordinator")

    public init(scriptBridge: any AppleScriptClient) {
        self.scriptBridge = scriptBridge
    }

    // MARK: Record

    /// Log a change after a successful write to Music.app.
    public func recordChange(_ entry: ChangeLogEntry) {
        history.append(entry)
        log
            .info(
                "Recorded \(entry.changeType.rawValue, privacy: .public) for track \(entry.trackID, privacy: .private)"
            )
    }

    /// Record multiple changes at once (e.g. after batch processing).
    public func recordChanges(_ entries: [ChangeLogEntry]) {
        history.append(contentsOf: entries)
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
            nil
        }

        guard let oldValue else {
            log.warning(
                "Cannot revert \(entry.changeType.rawValue, privacy: .public) for track \(entry.trackID, privacy: .private): no old value stored"
            )
            removeFromHistory(entry)
            return
        }

        try await scriptBridge.updateTrackProperty(
            trackID: entry.trackID,
            property: oldValue.property,
            value: oldValue.value
        )

        removeFromHistory(entry)
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

    /// Clear all history from memory.
    public func clearHistory() {
        let count = history.count
        history.removeAll()
        log.info("Cleared \(count, privacy: .public) history entries")
    }

    // MARK: Helpers

    private func removeFromHistory(_ entry: ChangeLogEntry) {
        history.removeAll { $0.id == entry.id }
    }
}
