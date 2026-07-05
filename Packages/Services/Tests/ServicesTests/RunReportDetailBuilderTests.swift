import Foundation
import Services
import Testing

@Suite("RunReportDetailBuilder")
struct RunReportDetailBuilderTests {
    private let startDate = Date(timeIntervalSince1970: 1_800_000_000)
    private let now = Date(timeIntervalSince1970: 1_800_000_480)

    @Test("completed detail maps identity and summary")
    func completedDetailMapsIdentityAndSummary() {
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: startDate.addingTimeInterval(45),
            state: .completed,
            syncSummary: ActivitySyncSummary(new: 2, modified: 2, identityChanged: 1, refreshed: 1, removed: 0)
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        #expect(detail.runID == record.runID.rawValue.uuidString)
        #expect(detail.state == .completed)
        #expect(detail.stateLabel == "Completed")
        #expect(detail.triggerLabel == "Manual check")
        #expect(detail.startedLabel == "8m ago")
        #expect(detail.durationLabel == "45s")
        #expect(detail.summaryItems == [
            RunReportSummaryItem(id: "summary-new", label: "New", value: "2"),
            RunReportSummaryItem(id: "summary-modified", label: "Modified", value: "2"),
            RunReportSummaryItem(id: "summary-identity-changed", label: "Identity changed", value: "1"),
            RunReportSummaryItem(id: "summary-refreshed", label: "Refreshed", value: "1"),
            RunReportSummaryItem(id: "summary-removed", label: "Removed", value: "0"),
            RunReportSummaryItem(id: "summary-total", label: "Total changes", value: "6"),
        ])
    }

    @Test("reporting transition renders reporting stage")
    func reportingTransitionRendersReportingStage() {
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: nil,
            state: .reporting,
            syncSummary: nil
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        #expect(detail.state == .running)
        #expect(detail.transitions.map(\.stageLabel) == ["Created", "Syncing library", "Reporting"])
    }

    @Test("running detail omits duration")
    func runningDetailOmitsDuration() {
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: nil,
            state: .syncingLibrary,
            syncSummary: nil
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        #expect(detail.state == .running)
        #expect(detail.stateLabel == "In progress")
        #expect(detail.durationLabel == nil)
    }

    @Test("full library scope produces scope lines")
    func fullLibraryScopeProducesScopeLines() {
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1234,
            createdAt: startDate,
            reason: "manual check"
        )
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: startDate.addingTimeInterval(45),
            state: .completed,
            syncSummary: nil,
            scope: scope
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        #expect(detail.scopeLines == [
            "Scope: Full library",
            "Known tracks: \(1234.formatted())",
        ])
    }

    @Test("test artist scope lists limited artists")
    func artistScopeListsLimitedArtists() {
        let fiveArtistScope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: ["A", "B", "C", "D", "E"],
            knownTrackCount: nil,
            createdAt: startDate,
            reason: ""
        )
        let twoArtistScope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: ["A", "B"],
            knownTrackCount: nil,
            createdAt: startDate,
            reason: ""
        )

        let fiveArtistDetail = RunReportDetailBuilder.makeDetail(
            from: makeRunRecord(
                startedAt: startDate,
                finishedAt: nil,
                state: .syncingLibrary,
                syncSummary: nil,
                scope: fiveArtistScope
            ),
            now: now
        )
        let twoArtistDetail = RunReportDetailBuilder.makeDetail(
            from: makeRunRecord(
                startedAt: startDate,
                finishedAt: nil,
                state: .syncingLibrary,
                syncSummary: nil,
                scope: twoArtistScope
            ),
            now: now
        )

        #expect(fiveArtistDetail.scopeLines.contains("Scope: Test artists (5)"))
        #expect(fiveArtistDetail.scopeLines.contains("Artists: A, B, C +2 more"))
        #expect(twoArtistDetail.scopeLines.contains("Artists: A, B"))
    }

    @Test("full library scope without known count is a single line")
    func fullLibraryScopeWithoutKnownCountIsSingleLine() {
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: nil,
            createdAt: startDate,
            reason: ""
        )
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: nil,
            state: .syncingLibrary,
            syncSummary: nil,
            scope: scope
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        #expect(detail.scopeLines == ["Scope: Full library"])
    }

    @Test("artist count at display limit omits hidden suffix")
    func artistCountAtDisplayLimitOmitsHiddenSuffix() {
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: ["A", "B", "C"],
            knownTrackCount: nil,
            createdAt: startDate,
            reason: ""
        )
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: nil,
            state: .syncingLibrary,
            syncSummary: nil,
            scope: scope
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        #expect(detail.scopeLines.contains("Artists: A, B, C"))
        #expect(!detail.scopeLines.contains { $0.contains("more") })
    }

    @Test("scope reason is never rendered")
    func scopeReasonIsNeverRendered() {
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: nil,
            createdAt: startDate,
            reason: "manualCheck"
        )
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: nil,
            state: .syncingLibrary,
            syncSummary: nil,
            scope: scope
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        #expect(!detail.scopeLines.contains { $0.hasPrefix("Reason:") })
    }

    @Test("transitions map to timeline")
    func transitionsMapToTimeline() {
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: startDate.addingTimeInterval(45),
            state: .completed,
            syncSummary: nil
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        #expect(detail.transitions.map(\.stageLabel) == ["Created", "Syncing library", "Completed"])
        #expect(detail.transitions.map(\.id) == ["transition-0", "transition-1", "transition-2"])
        #expect(detail.transitions.map(\.timeLabel) == ["8m ago", "7m ago", "7m ago"])
    }

    @Test("failed detail carries failure message")
    func failedDetailCarriesFailureMessage() {
        let withMessage = makeRunRecord(
            startedAt: startDate,
            finishedAt: startDate.addingTimeInterval(45),
            state: .failed,
            syncSummary: nil,
            failureMessage: "Music.app unavailable"
        )
        let withoutMessage = makeRunRecord(
            startedAt: startDate,
            finishedAt: startDate.addingTimeInterval(45),
            state: .failed,
            syncSummary: nil,
            failureMessage: nil
        )

        #expect(RunReportDetailBuilder.makeDetail(from: withMessage, now: now)
            .failureMessage == "Music.app unavailable")
        #expect(RunReportDetailBuilder.makeDetail(from: withoutMessage, now: now).failureMessage == "Run failed")
    }

    @Test("missing summary produces no summary items")
    func missingSummaryProducesNoSummaryItems() {
        let record = makeRunRecord(startedAt: startDate, finishedAt: nil, state: .syncingLibrary, syncSummary: nil)

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        #expect(detail.summaryItems.isEmpty)
    }

    private func makeRunRecord(
        runID: RunID = RunID(),
        trigger: RunTrigger = .manualCheck,
        startedAt: Date,
        finishedAt: Date?,
        state: RunLifecycleState,
        syncSummary: ActivitySyncSummary?,
        failureMessage: String? = nil,
        scope: ProcessingScopeSnapshot? = nil
    ) -> RunRecord {
        var transitions = [
            RunLifecycleTransition(state: .created, timestamp: startedAt),
            RunLifecycleTransition(state: .syncingLibrary, timestamp: startedAt.addingTimeInterval(1)),
        ]
        if state != .syncingLibrary {
            transitions.append(RunLifecycleTransition(
                state: state,
                timestamp: finishedAt ?? startedAt.addingTimeInterval(2)
            ))
        }

        return RunRecord(
            runID: runID,
            requestID: RunRequestID(),
            trigger: trigger,
            intent: .observeLibrary,
            scope: scope ?? ProcessingScopeSnapshot.capture(
                requestedTestArtists: [],
                knownTrackCount: nil,
                createdAt: startedAt,
                reason: ""
            ),
            transitions: transitions,
            syncSummary: syncSummary,
            failureMessage: failureMessage,
            startedAt: startedAt,
            finishedAt: finishedAt
        )
    }
}
