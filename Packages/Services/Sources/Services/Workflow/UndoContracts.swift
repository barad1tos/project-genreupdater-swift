import Core
import Foundation

/// Retry contract: prepared may dispatch; dispatchedUnknown blocks; changed
/// and noChange still require mirror finalization; completed may only clean up.
enum BackupRestorePhase: String, Codable {
    case prepared
    case dispatchedUnknown
    case changed
    case noChange
    case completed
}

enum YearCheckpointPurpose {
    case backupRestore
    case historyUndo
}

enum UndoCoordinatorError: Error, LocalizedError {
    case revertFailed(trackID: String, reason: String)
    case noChangesToRevert
    case partialRevertFailure(succeeded: Int, failed: Int, errorDescriptions: [String])
    case invalidBackupCSV(reason: String)
    case missingAppleScriptID(trackID: String)
    case historyStoreUnavailable
    case undoOutcomeUnknown(trackID: String)
    case undoWriteNotApplied(trackID: String)
    case undoRecoveryConflict(trackID: String)
    case recoveryStorageFailed(trackID: String)

    var errorDescription: String? {
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
        case .historyStoreUnavailable:
            "Durable change history is unavailable"
        case let .undoOutcomeUnknown(trackID):
            "Could not verify whether undo updated track \(trackID). Try again after Music.app is available"
        case let .undoWriteNotApplied(trackID):
            "Undo did not update track \(trackID); no metadata was changed. Try again"
        case let .undoRecoveryConflict(trackID):
            "Undo recovery for track \(trackID) conflicts with current Music.app state"
        case let .recoveryStorageFailed(trackID):
            "GenreUpdater could not access undo recovery state for track \(trackID). Retry before making more changes"
        }
    }

    var blocksBatchRevert: Bool {
        switch self {
        case .undoOutcomeUnknown, .undoWriteNotApplied, .undoRecoveryConflict, .recoveryStorageFailed:
            true
        case .revertFailed,
             .noChangesToRevert,
             .partialRevertFailure,
             .invalidBackupCSV,
             .missingAppleScriptID,
             .historyStoreUnavailable:
            false
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
    public let skippedCount: Int
    public let missingCount: Int
    public let failedCount: Int
    public let firstFailureDescription: String?

    public init(
        parsedCount: Int,
        updatedCount: Int,
        skippedCount: Int = 0,
        missingCount: Int,
        failedCount: Int = 0,
        firstFailureDescription: String? = nil
    ) {
        self.parsedCount = parsedCount
        self.updatedCount = updatedCount
        self.skippedCount = skippedCount
        self.missingCount = missingCount
        self.failedCount = failedCount
        self.firstFailureDescription = firstFailureDescription
    }
}

extension UndoCoordinator {
    public struct Stores: Sendable {
        let changeLog: (any ChangeLogStore)?
        let tracks: (any TrackStateStore)?
        let cache: (any CacheService)?

        public init(
            changeLog: (any ChangeLogStore)? = nil,
            tracks: (any TrackStateStore)? = nil,
            cache: (any CacheService)? = nil
        ) {
            self.changeLog = changeLog
            self.tracks = tracks
            self.cache = cache
        }
    }
}
