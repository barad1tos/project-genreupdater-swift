import Core
import Foundation

enum UndoCoordinatorError: Error, LocalizedError {
    case revertFailed(trackID: String, reason: String)
    case noChangesToRevert
    case partialRevertFailure(succeeded: Int, failed: Int, errorDescriptions: [String])
    case invalidBackupCSV(reason: String)
    case missingAppleScriptID(trackID: String)
    case historyStoreUnavailable

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
    public struct Stores {
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
