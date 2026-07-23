import Foundation

extension UpdateCoordinator {
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
