import Core
import Foundation

extension UpdateCoordinator {
    /// Resolves a `WriteAttemptFailure` to the error worth throwing, logging
    /// the displaced checkpoint error when the unknown outcome wins so its
    /// evidence is not silently dropped (mirrors the bridge-side log).
    func reportAttemptFailure(_ failure: WriteAttemptFailure) -> any Error {
        let reported = failure.reportedError
        if reported is AppleScriptOutcomeError {
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
