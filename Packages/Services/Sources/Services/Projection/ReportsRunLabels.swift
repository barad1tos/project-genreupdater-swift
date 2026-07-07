import Foundation

enum ReportsRunLabels {
    static func runState(from state: RunLifecycleState) -> ReportsRunState {
        switch state {
        case .created, .syncingLibrary, .planningFixes, .reporting:
            .running
        case .completed:
            .completed
        case .completedNoOp:
            .completedNoOp
        case .failed:
            .failed
        }
    }

    static func stateLabel(for state: ReportsRunState) -> String {
        switch state {
        case .running:
            "In progress"
        case .completed:
            "Completed"
        case .completedNoOp:
            "Completed · no changes"
        case .failed:
            "Failed"
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

    static func stageLabel(for state: RunLifecycleState) -> String {
        switch state {
        case .created:
            "Created"
        case .syncingLibrary:
            "Syncing library"
        case .planningFixes:
            "Planning fixes"
        case .reporting:
            "Reporting"
        case .completed:
            "Completed"
        case .completedNoOp:
            "Completed · no changes"
        case .failed:
            "Failed"
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
        case .observeLibrary:
            true
        case .previewFixes:
            false
        }
    }

    static func failureSummary(state: ReportsRunState, failureMessage: String?) -> String? {
        guard state == .failed else { return nil }
        return failureMessage ?? "Run failed"
    }
}
