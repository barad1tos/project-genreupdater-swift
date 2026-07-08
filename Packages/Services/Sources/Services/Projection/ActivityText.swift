import Foundation

extension ActivityProjectionBuilder {
    static func makeTitle(input: ActivityProjectionInput) -> String {
        makeBlockingLibraryTitle(input: input)
            ?? makeRecoveryTitle(input: input)
            ?? makeSyncTitle(input: input)
            ?? makeLibraryProgressTitle(input: input)
            ?? makeWorkflowTitle(input: input)
            ?? "Library ready"
    }

    static func makeBlockingLibraryTitle(input: ActivityProjectionInput) -> String? {
        switch input.libraryState {
        case .permissionDenied, .failed:
            "Library needs attention"
        case .loading, .empty, .ready:
            nil
        }
    }

    static func makeRecoveryTitle(input: ActivityProjectionInput) -> String? {
        guard input.hasRecovery else { return nil }
        return "Recovery needed"
    }

    static func makeSyncTitle(input: ActivityProjectionInput) -> String? {
        input.effectiveSyncState.title
    }

    static func makeLibraryProgressTitle(input: ActivityProjectionInput) -> String? {
        switch input.libraryState {
        case .loading:
            "Scanning library"
        case .empty:
            "Library empty"
        case .ready, .permissionDenied, .failed:
            nil
        }
    }

    static func makeWorkflowTitle(input: ActivityProjectionInput) -> String? {
        if input.workflow.isProcessing {
            return input.workflow.phaseLabel
        }
        if input.proposedFixCount > 0 {
            return "Fix plan ready"
        }
        return nil
    }

    static func makeSubtitle(input: ActivityProjectionInput, syncSummary: ActivitySyncSummary?) -> String {
        if let libraryStateSubtitle = makeLibraryStateSubtitle(input: input) {
            return libraryStateSubtitle
        }

        if input.hasRecovery {
            return "Previous run needs recovery before writes continue"
        }

        if let syncSubtitle = input.effectiveSyncState.subtitle {
            return syncSubtitle
        }

        if input.proposedFixCount > 0 {
            let mode = input.processingMode == .preview ? "preview mode · no Music tags written" : "write mode"
            return "\(input.proposedFixCount.formatted()) candidate fixes · \(mode)"
        }

        if case .completed = input.effectiveSyncState, let syncSummary {
            return syncSummary.resultDetail
        }

        return "Library ready"
    }

    static func makeLibraryStateSubtitle(input: ActivityProjectionInput) -> String? {
        switch input.libraryState {
        case let .permissionDenied(message), let .failed(message):
            return message
        case .loading:
            // Active/problem runs take precedence over transient library loading copy.
            guard input.effectiveSyncState == .idle else { return nil }
            if input.isAutoSyncRunning {
                return "Auto-sync running · reading Music metadata"
            }
            return "Manual scan in progress"
        case .empty:
            return input.effectiveSyncState == .idle ? "No Music tracks available for analysis" : nil
        case .ready:
            return nil
        }
    }

    static func hasLibraryBlocker(input: ActivityProjectionInput) -> Bool {
        switch input.libraryState {
        case .permissionDenied, .failed:
            true
        case .loading, .empty, .ready:
            false
        }
    }

    static func makeSyncStatusText(input: ActivityProjectionInput) -> String {
        if input.hasRecovery, !hasLibraryBlocker(input: input) {
            return "Recovery needed"
        }

        if let statusText = input.effectiveSyncState.statusText {
            return statusText
        }

        if case .loading = input.libraryState {
            return "Scanning"
        }
        if let lastScanDate = input.effectiveLastScanDate {
            let relativeTime = relativeTime(from: lastScanDate, to: input.now)
            return relativeTime == "just now" ? "Synced just now" : "Synced \(relativeTime) ago"
        }
        return input.isAutoSyncRunning ? "Auto-sync running" : "No sync yet"
    }

    static func relativeTime(from date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 {
            return "just now"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h"
        }
        return "\(hours / 24)d"
    }
}
