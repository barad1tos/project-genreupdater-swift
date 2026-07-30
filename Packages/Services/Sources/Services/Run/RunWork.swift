import Core

extension RunOrchestrator {
    struct RunWork {
        let reportingSource: RunLifecycleSnapshot
        let result: SyncResult
        let hasActionableWork: Bool
        let writeSummary: RunWriteSummary?
        let failureMessage: String?
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
