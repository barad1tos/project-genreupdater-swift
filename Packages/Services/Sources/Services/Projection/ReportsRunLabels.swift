import Foundation

enum ReportsRunLabels {
    static func runState(from record: RunRecord, activeRunID: RunID? = nil) -> ReportsRunState {
        let state = runState(from: record.state)
        guard record.finishedAt == nil, record.runID != activeRunID else {
            return state
        }
        switch state {
        case .running:
            return .recoveryNeeded
        case .awaitingReview,
             .completed,
             .completedNoOp,
             .blocked,
             .failed,
             .cancelled,
             .recoveryNeeded:
            return state
        }
    }

    static func runState(from state: RunLifecycleState) -> ReportsRunState {
        switch state {
        case .created,
             .queued,
             .syncingLibrary,
             .analyzingDelta,
             .planningFixes,
             .writing,
             .verifying,
             .reporting,
             .recovering:
            .running
        case .awaitingReview:
            .awaitingReview
        case .completed:
            .completed
        case .completedNoOp:
            .completedNoOp
        case .blocked:
            .blocked
        case .failed:
            .failed
        case .cancelled:
            .cancelled
        case .recoverable:
            .recoveryNeeded
        }
    }

    static func stateLabel(for state: ReportsRunState) -> String {
        switch state {
        case .running:
            "In progress"
        case .awaitingReview:
            "Awaiting review"
        case .completed:
            "Completed"
        case .completedNoOp:
            "Completed · no changes"
        case .blocked:
            "Blocked"
        case .failed:
            "Failed"
        case .cancelled:
            "Cancelled"
        case .recoveryNeeded:
            "Recovery needed"
        }
    }

    static func triggerLabel(for trigger: RunTrigger) -> String {
        switch trigger {
        case .manualCheck:
            "Manual check"
        case .backgroundSync:
            "Background sync"
        case .fileSystemEvent:
            "File system event"
        case .recovery:
            "Recovery"
        }
    }

    static func modeLabel(for intent: RunIntent) -> String {
        switch intent {
        case .observeLibrary:
            "Library check"
        case .previewFixes:
            "Preview"
        case .writeFixes:
            "Auto-fix"
        }
    }

    static func scopeLabel(for scope: ProcessingScopeSnapshot) -> String {
        let scopeText = scopeSourceLabel(for: scope)

        guard let trackCount = scope.knownTrackCount else {
            return scopeText
        }
        let trackText = trackCount == 1 ? "1 track" : "\(trackCount.formatted()) tracks"
        return "\(scopeText) · \(trackText)"
    }

    static func scopeSourceLabel(for scope: ProcessingScopeSnapshot) -> String {
        switch scope.source {
        case .fullLibrary:
            "Full library"
        case .testArtists:
            "Test artists (\(scope.normalizedTestArtists.count))"
        }
    }

    // Keep this switch exhaustive so adding a RunLifecycleState requires a matching report label.
    // swiftlint:disable:next cyclomatic_complexity
    static func stageLabel(for state: RunLifecycleState) -> String {
        switch state {
        case .created:
            "Created"
        case .queued:
            "Queued"
        case .syncingLibrary:
            "Syncing library"
        case .analyzingDelta:
            "Analyzing delta"
        case .planningFixes:
            "Planning fixes"
        case .awaitingReview:
            "Awaiting review"
        case .writing:
            "Writing"
        case .verifying:
            "Verifying"
        case .reporting:
            "Reporting"
        case .completed:
            "Completed"
        case .completedNoOp:
            "Completed · no changes"
        case .blocked:
            "Blocked"
        case .failed:
            "Failed"
        case .cancelled:
            "Cancelled"
        case .recoverable:
            "Recoverable"
        case .recovering:
            "Recovering"
        }
    }

    static func relativeLabel(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 {
            return "just now"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m ago"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h ago"
        }
        return "\(hours / 24)d ago"
    }

    static func durationLabel(startedAt: Date, finishedAt: Date?) -> String? {
        guard let finishedAt else { return nil }
        let totalSeconds = max(0, Int(finishedAt.timeIntervalSince(startedAt)))
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        let totalMinutes = totalSeconds / 60
        let remainderSeconds = totalSeconds % 60
        if totalMinutes < 60 {
            return remainderSeconds == 0 ? "\(totalMinutes)m" : "\(totalMinutes)m \(remainderSeconds)s"
        }
        let hours = totalMinutes / 60
        let remainderMinutes = totalMinutes % 60
        return remainderMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainderMinutes)m"
    }

    static func changeCountLabel(for summary: ActivitySyncSummary?, intent: RunIntent) -> String? {
        guard showsSyncSummary(for: intent) else { return nil }
        guard let summary else { return nil }
        let count = summary.changeCount
        if count == 0 {
            return "No changes"
        }
        return count == 1 ? "1 change" : "\(count.formatted()) changes"
    }

    static func showsSyncSummary(for intent: RunIntent) -> Bool {
        switch intent {
        case .observeLibrary,
             .writeFixes:
            true
        case .previewFixes:
            false
        }
    }

    static func failureSummary(state: ReportsRunState, failureMessage: String?) -> String? {
        switch state {
        case .failed:
            failureMessage ?? "Run failed"
        case .blocked:
            failureMessage ?? "Run blocked"
        case .cancelled:
            failureMessage ?? "Run cancelled"
        case .recoveryNeeded:
            "Previous run needs recovery"
        case .running, .awaitingReview, .completed, .completedNoOp:
            nil
        }
    }
}
