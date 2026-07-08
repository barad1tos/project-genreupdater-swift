extension ActivityProjectionBuilder {
    static func makeRecentActivity(
        input: ActivityProjectionInput,
        counts: Counts,
        syncSummary: ActivitySyncSummary?
    ) -> [ActivityRecentItem] {
        var items: [ActivityRecentItem] = []
        switch input.libraryState {
        case .ready:
            items.append(ActivityRecentItem(
                id: "scan",
                title: "Library scan",
                detail: "\(counts.totalTracks) tracks analyzed"
            ))
        case .loading:
            items.append(ActivityRecentItem(id: "scan", title: "Library scan", detail: "Scanning in progress"))
        case .empty:
            items.append(ActivityRecentItem(id: "scan", title: "Library scan", detail: "No tracks found"))
        case let .permissionDenied(message), let .failed(message):
            items.append(ActivityRecentItem(id: "scan", title: "Library scan", detail: message))
        }

        if let syncSummary {
            items.append(ActivityRecentItem(
                id: "library-sync",
                title: "Library sync",
                detail: syncSummary.resultDetail
            ))
        }
        if let recentIssue = input.effectiveSyncState.recentIssue {
            items.append(recentIssue)
        }
        return items
    }

    static func makeSummaryCards(
        input: ActivityProjectionInput,
        counts: Counts,
        syncSummary: ActivitySyncSummary?
    ) -> [ActivitySummaryCard] {
        let automationState = makeAutomationState(input: input)
        let deltaValue: Int
        let deltaDetail: String
        if input.proposedFixCount > 0 {
            deltaValue = input.proposedFixCount
            deltaDetail = "candidate fixes"
        } else {
            deltaValue = syncSummary?.changeCount ?? 0
            deltaDetail = "library changes"
        }

        return [
            ActivitySummaryCard(
                id: "automation",
                kind: .automation,
                label: "Automation",
                value: automationState == .autoSyncRunning ? "Running" : "Manual",
                detail: automationState == .autoSyncRunning ? "Auto-sync running" : "Manual scan only"
            ),
            ActivitySummaryCard(
                id: "delta",
                kind: .delta,
                label: "Delta",
                value: "\(deltaValue)",
                detail: deltaDetail
            ),
            ActivitySummaryCard(
                id: "quality",
                kind: .quality,
                label: "Quality",
                value: qualityPercentage(from: counts),
                detail: "reporting context"
            )
        ]
    }

    static func qualityPercentage(from counts: Counts) -> String {
        guard counts.totalTracks > 0 else { return "0%" }
        let percentage = Double(counts.tracksWithBoth) / Double(counts.totalTracks) * 100
        return "\(Int(percentage.rounded()))%"
    }
}
