import Core
import Foundation

public enum UpdateCoordinatorError: Error, LocalizedError {
    case trackNotEditable(trackID: String)
    case trackNotProcessable(trackID: String, status: String)
    case noChangesProduced
    case duplicateChangeID(UUID)
    case allTracksFailed(count: Int, errorDescriptions: [String])
    case missingAppleScriptID(trackID: String)
    case reviewedChangeStale(trackID: String, property: String)
    case writeFailed(trackID: String, property: String, reason: String)
    case writeFinalizationFailed(trackID: String, effects: [String])

    public var errorDescription: String? {
        switch self {
        case let .trackNotEditable(trackID):
            "Track \(trackID) is not editable"
        case let .trackNotProcessable(trackID, status):
            "Track \(trackID) is not processable in its current status: \(status)"
        case .noChangesProduced:
            "No changes were produced for the given tracks"
        case let .duplicateChangeID(changeID):
            "Cannot apply reviewed changes: duplicate change ID \(changeID.uuidString)"
        case let .allTracksFailed(count, errorDescriptions):
            Self.allTracksFailedDescription(count: count, errorDescriptions: errorDescriptions)
        case let .missingAppleScriptID(trackID):
            "Cannot write track \(trackID): no AppleScript ID mapping is available"
        case let .reviewedChangeStale(trackID, property):
            "Cannot write \(property) for track \(trackID): reviewed value no longer matches Music.app"
        case let .writeFailed(trackID, property, reason):
            "Failed to write \(property) for track \(trackID): \(reason)"
        case let .writeFinalizationFailed(trackID, effects):
            "Music.app updated track \(trackID), but GenreUpdater could not persist \(effects.joined(separator: " and "))"
        }
    }

    private static func allTracksFailedDescription(count: Int, errorDescriptions: [String]) -> String {
        let visibleErrors = errorDescriptions.filter { !$0.isEmpty }
        guard !visibleErrors.isEmpty else {
            return "All \(count) tracks failed to update"
        }
        if count == 1, visibleErrors.count == 1 {
            return visibleErrors[0]
        }
        if count == 1 {
            return "All \(visibleErrors.count) update operations failed for 1 track. Errors: \(visibleErrors.joined(separator: "; "))"
        }
        return "All \(count) tracks failed to update across \(visibleErrors.count) update operations. Errors: \(visibleErrors.joined(separator: "; "))"
    }
}

extension UpdateCoordinator {
    /// Resolves a `WriteAttemptFailure` to the error worth throwing, logging
    /// the displaced checkpoint error when the unknown outcome wins so its
    /// evidence is not silently dropped (mirrors the bridge-side log).
    func reportAttemptFailure(_ failure: WriteAttemptFailure) -> any Error {
        let reported = failure.reportedError
        if failure.writeError is AppleScriptOutcomeError, !(reported is WorkCheckpointError) {
            log.error("""
            Attempt hook failed with \(String(describing: type(of: failure.checkpointError)), privacy: .public): \
            \(failure.checkpointError.localizedDescription, privacy: .private); reporting the unknown write outcome
            """)
        }
        return reported
    }

    func recordWorkflowWriteFailure(
        _ error: any Error,
        isReviewedChange: Bool,
        trackID: String,
        failedTrackIDs: inout [String],
        errorDescriptions: inout [String]
    ) throws {
        if error is CancellationError {
            throw CancellationError()
        }
        if let outcomeError = error as? AppleScriptOutcomeError {
            throw outcomeError
        }
        if let coordinatorError = error as? UpdateCoordinatorError {
            if case .writeFinalizationFailed = coordinatorError {
                throw coordinatorError
            }
            if recordKnownWorkflowFailure(
                coordinatorError,
                fallbackTrackID: trackID,
                isReviewedChange: isReviewedChange,
                failedTrackIDs: &failedTrackIDs,
                errorDescriptions: &errorDescriptions
            ) {
                return
            }
        }
        recordUnexpectedFailure(
            trackID: trackID,
            error: error,
            failedTrackIDs: &failedTrackIDs,
            errorDescriptions: &errorDescriptions
        )
    }
}
