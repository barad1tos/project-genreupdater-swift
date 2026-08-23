import Core

extension RunOrchestrator {
    struct RunWork {
        let reportingSource: RunLifecycleSnapshot
        let result: SyncResult
        let hasActionableWork: Bool
        let writeSummary: RunWriteSummary?
        let failureMessage: String?
        let producedPlanID: FixPlanID?

        init(
            reportingSource: RunLifecycleSnapshot,
            result: SyncResult,
            hasActionableWork: Bool,
            writeSummary: RunWriteSummary?,
            failureMessage: String?,
            producedPlanID: FixPlanID? = nil
        ) {
            self.reportingSource = reportingSource
            self.result = result
            self.hasActionableWork = hasActionableWork
            self.writeSummary = writeSummary
            self.failureMessage = failureMessage
            self.producedPlanID = producedPlanID
        }
    }

    /// The batch mirrors the write's result contract without its ledger:
    /// change-log entries persist inside the runner's coordinator path,
    /// so the run record and write summary are the only new truth here.
    func performBatch(
        _ input: BatchRunInput,
        from lifecycle: RunLifecycleSnapshot
    ) async throws -> RunWork {
        guard let runBatchUpdate = dependencies.runBatchUpdate else {
            throw RunWorkError.missingBatchRunner
        }
        let result = try await runBatchUpdate(input, lifecycle.runID)
        let failureMessage: String? = if result.failedOperationCount > 0 {
            RunWorkError.writeFailure(
                failedOperationCount: result.failedOperationCount,
                failedTrackCount: result.failedTrackCount,
                reasons: result.errorDescriptions,
                isPartial: result.hasPartialFailures
            ).localizedDescription
        } else {
            nil
        }
        return RunWork(
            reportingSource: activeRun ?? lifecycle,
            result: Self.makeWriteSyncResult(from: result),
            hasActionableWork: result.appliedOperationCount > 0,
            writeSummary: RunWriteSummary(
                applied: result.appliedOperationCount,
                verifiedNoOp: result.noOpEntries.count,
                failed: result.failedOperationCount
            ),
            failureMessage: failureMessage
        )
    }

    static func makeWriteSyncResult(from result: BatchUpdateResult) -> SyncResult {
        SyncResult(modifiedTracks: result.entries.map { entry in
            Track(
                id: entry.trackID,
                name: entry.trackName,
                artist: entry.artist,
                album: entry.albumName
            )
        })
    }
}
