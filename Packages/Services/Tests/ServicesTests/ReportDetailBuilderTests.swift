import Core
import Foundation
import Testing
@testable import Services

@Suite("RunReportDetailBuilder")
struct ReportDetailBuilderTests {
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

    @Test("lineage lines surface continuation, plan and write evidence")
    func lineageLinesSurfaceEvidence() {
        let source = RunID()
        let planID = FixPlanID()
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: startDate.addingTimeInterval(45),
            state: .cancelled,
            syncSummary: nil,
            input: RecordInput(
                intent: .writeFixes,
                writeTarget: FixPlanWriteTarget(
                    planID: planID,
                    planRevision: .initial,
                    decisionRevision: .initial
                ),
                continuesRunID: source,
                writeSummary: RunWriteSummary(applied: 3, verifiedNoOp: 1, failed: 2)
            )
        )
        let continuedBy = RunID()

        let detail = RunReportDetailBuilder.makeDetail(
            from: record,
            now: now,
            continuedBy: [continuedBy]
        )

        #expect(detail.lineageLines == [
            "Continues run \(source.rawValue.uuidString.prefix(8))",
            "Continued by \(continuedBy.rawValue.uuidString.prefix(8))",
            "Plan \(planID.rawValue.uuidString.prefix(8)) · rev 1.1",
            "Writes: 3 applied · 1 no-op · 2 failed",
        ])
    }

    @Test("an unlinked observation run has no lineage lines")
    func unlinkedRunHasNoLineageLines() {
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: startDate.addingTimeInterval(45),
            state: .completed,
            syncSummary: nil
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        #expect(detail.lineageLines.isEmpty)
    }

    @Test("preview no-op omits library delta from detail summary")
    func previewHidesDelta() {
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: startDate.addingTimeInterval(45),
            state: .completedNoOp,
            syncSummary: ActivitySyncSummary(new: 2, modified: 3, identityChanged: 0, refreshed: 0, removed: 0),
            input: RecordInput(intent: .previewFixes)
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        #expect(detail.stateLabel == "Completed · no changes")
        #expect(detail.summaryItems.isEmpty)
    }

    @Test("reporting transition renders reporting stage")
    func reportingTransitionRendersReportingStage() {
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: nil,
            state: .reporting,
            syncSummary: nil
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now, activeRunID: record.runID)

        #expect(detail.state == .running)
        #expect(detail.transitions.map(\.stageLabel) == ["Created", "Syncing library", "Reporting"])
    }

    @Test("planning fixes transition renders planning fixes stage")
    func planningFixesTransitionRendersPlanningFixesStage() {
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: nil,
            state: .planningFixes,
            syncSummary: nil
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now, activeRunID: record.runID)

        #expect(detail.state == .running)
        #expect(detail.transitions.map(\.stageLabel) == ["Created", "Syncing library", "Planning fixes"])
    }

    @Test("canonical lifecycle transitions have display labels")
    func canonicalTransitionsHaveLabels() {
        let cases: [(RunLifecycleState, String)] = [
            (.created, "Created"),
            (.queued, "Queued"),
            (.syncingLibrary, "Syncing library"),
            (.analyzingDelta, "Analyzing delta"),
            (.planningFixes, "Planning fixes"),
            (.awaitingReview, "Awaiting review"),
            (.writing, "Writing"),
            (.verifying, "Verifying"),
            (.reporting, "Reporting"),
            (.completed, "Completed"),
            (.completedNoOp, "Completed · no changes"),
            (.blocked, "Blocked"),
            (.failed, "Failed"),
            (.cancelled, "Cancelled"),
            (.recoverable, "Recoverable"),
            (.recovering, "Recovering"),
        ]
        #expect(cases.map(\.0) == Array(RunLifecycleState.allCases))

        let transitions = cases.enumerated().map { index, entry in
            RunLifecycleTransition(state: entry.0, timestamp: startDate.addingTimeInterval(Double(index)))
        }
        let record = RunRecord(
            header: RunRecord.Header(
                runID: RunID(),
                requestID: RunRequestID(),
                trigger: .manualCheck,
                intent: .observeLibrary,
                scope: ProcessingScopeSnapshot.capture(
                    requestedTestArtists: [],
                    knownTrackCount: nil,
                    createdAt: startDate,
                    reason: ""
                ),
                continuesRunID: nil,
                startedAt: startDate
            ),
            transitions: transitions,
            status: RunRecord.Status(
                syncSummary: nil,
                failureMessage: nil,
                finishedAt: nil
            )
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now, activeRunID: record.runID)

        #expect(detail.transitions.map(\.stageLabel) == cases.map(\.1))
    }

    @Test("running detail omits duration")
    func runningDetailOmitsDuration() {
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: nil,
            state: .syncingLibrary,
            syncSummary: nil
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now, activeRunID: record.runID)

        #expect(detail.state == .running)
        #expect(detail.stateLabel == "In progress")
        #expect(detail.durationLabel == nil)
    }

    @Test("open persisted read detail maps to failed")
    func openReadFails() {
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: nil,
            state: .reporting,
            syncSummary: nil
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        #expect(detail.state == .failed)
        #expect(detail.stateLabel == "Failed")
        #expect(detail.durationLabel == nil)
        #expect(detail.detailMessage == "Run failed")
        #expect(detail.transitions.map(\.stageLabel) == ["Created", "Syncing library", "Reporting"])
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
            input: RecordInput(scope: scope)
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        #expect(detail.scopeLines == [
            "Scope: Full library",
            "Known tracks: \(1234.formatted())",
        ])
    }

    @Test("test artist scope lists artists and omits track count")
    func rendersArtistScope() {
        let fiveArtistScope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: ["A", "B", "C", "D", "E"],
            knownTrackCount: nil,
            createdAt: startDate,
            reason: ""
        )
        let twoArtistScope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: ["A", "B"],
            knownTrackCount: 44,
            createdAt: startDate,
            reason: ""
        )

        let fiveArtistDetail = RunReportDetailBuilder.makeDetail(
            from: makeRunRecord(
                startedAt: startDate,
                finishedAt: nil,
                state: .syncingLibrary,
                syncSummary: nil,
                input: RecordInput(scope: fiveArtistScope)
            ),
            now: now
        )
        let twoArtistDetail = RunReportDetailBuilder.makeDetail(
            from: makeRunRecord(
                startedAt: startDate,
                finishedAt: nil,
                state: .syncingLibrary,
                syncSummary: nil,
                input: RecordInput(scope: twoArtistScope)
            ),
            now: now
        )

        #expect(fiveArtistDetail.scopeLines.contains("Scope: Test artists (5)"))
        #expect(fiveArtistDetail.scopeLines.contains("Artists: A, B, C +2 more"))
        #expect(twoArtistDetail.scopeLines == [
            "Scope: Test artists (2)",
            "Artists: A, B",
        ])
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
            input: RecordInput(scope: scope)
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
            input: RecordInput(scope: scope)
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
            input: RecordInput(scope: scope)
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
            input: RecordInput(failureMessage: "Music.app unavailable")
        )
        let withoutMessage = makeRunRecord(
            startedAt: startDate,
            finishedAt: startDate.addingTimeInterval(45),
            state: .failed,
            syncSummary: nil,
            input: RecordInput(failureMessage: nil)
        )

        #expect(RunReportDetailBuilder.makeDetail(from: withMessage, now: now)
            .detailMessage == "Music.app unavailable")
        #expect(RunReportDetailBuilder.makeDetail(from: withoutMessage, now: now).detailMessage == "Run failed")
    }

    @Test("completed recovery exposes its audit message")
    func completedRecoveryShowsAudit() {
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: startDate.addingTimeInterval(45),
            state: .completed,
            syncSummary: nil,
            input: RecordInput(failureMessage: "Recovery closed after Music.app verification.")
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        #expect(detail.detailMessage == "Recovery closed after Music.app verification.")
    }

    @Test("missing summary produces no summary items")
    func missingSummaryProducesNoSummaryItems() {
        let record = makeRunRecord(startedAt: startDate, finishedAt: nil, state: .syncingLibrary, syncSummary: nil)

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        #expect(detail.summaryItems.isEmpty)
    }

    @Test("work items map with labels and open flags")
    func mapsWorkItems() {
        let prepared = makeWorkItem(state: .prepared, oldValue: "Rock", newValue: "Metal")
        let attempted = makeWorkItem(state: .attempted)
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: nil,
            state: .recoverable,
            syncSummary: nil,
            input: RecordInput(intent: .writeFixes, workItems: [prepared, attempted])
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        #expect(detail.workItems.count == 2)
        let first = detail.workItems[0]
        #expect(first.id == prepared.id)
        #expect(first.changeLabel.contains("Rock"))
        #expect(first.changeLabel.contains("Metal"))
        #expect(first.isOpen)
        #expect(!first.isWriteUncertain)
        #expect(detail.workItems[1].isWriteUncertain)
        #expect(detail.canDismissItems)
    }

    @Test("a closed write run with failed work can apply remaining fixes")
    func closedRunWithFailuresCanContinue() {
        let failed = makeWorkItem(state: .outcome(.failed))
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: startDate.addingTimeInterval(10),
            state: .cancelled,
            syncSummary: nil,
            input: RecordInput(intent: .writeFixes, writeTarget: writeTarget(), workItems: [failed])
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        #expect(detail.canApplyRemainingFixes)
        #expect(!detail.canDismissItems)
    }

    @Test("a salvaged run without a recorded plan offers no continuation")
    func runWithoutRecordedPlanOffersNoContinuation() {
        let failed = makeWorkItem(state: .outcome(.failed))
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: startDate.addingTimeInterval(10),
            state: .cancelled,
            syncSummary: nil,
            input: RecordInput(intent: .writeFixes, writeTarget: nil, workItems: [failed])
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        #expect(!detail.canApplyRemainingFixes)
    }

    @Test("a fully landed closed run offers no continuation")
    func fullyLandedRunOffersNoContinuation() {
        let written = makeWorkItem(state: .outcome(.written))
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: startDate.addingTimeInterval(10),
            state: .cancelled,
            syncSummary: nil,
            input: RecordInput(intent: .writeFixes, workItems: [written])
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        #expect(!detail.canApplyRemainingFixes)
        #expect(!detail.canDismissItems)
    }

    @Test("a live writing run offers no dismissal")
    func writingRunOffersNoDismissal() {
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: nil,
            state: .writing,
            syncSummary: nil,
            input: RecordInput(intent: .writeFixes, workItems: [makeWorkItem(state: .prepared)])
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        #expect(!detail.canDismissItems)
    }

    @Test("the active run offers no dismissal even when recoverable")
    func activeRunOffersNoDismissal() {
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: nil,
            state: .recoverable,
            syncSummary: nil,
            input: RecordInput(intent: .writeFixes, workItems: [makeWorkItem(state: .prepared)])
        )

        let active = RunReportDetailBuilder.makeDetail(from: record, now: now, activeRunID: record.runID)
        let inactive = RunReportDetailBuilder.makeDetail(from: record, now: now, activeRunID: RunID())

        #expect(!active.canDismissItems)
        #expect(inactive.canDismissItems)
    }

    @Test("an open recovery run without open items offers no dismissal")
    func recoveryRunWithoutOpenItemsOffersNoDismissal() {
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: nil,
            state: .recoverable,
            syncSummary: nil,
            input: RecordInput(intent: .writeFixes, workItems: [makeWorkItem(state: .outcome(.failed))])
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        #expect(!detail.canDismissItems)
    }

    @Test("an evidence-less legacy no-op offers one acknowledgement without pretending to be open")
    func legacyNoOpOffersAcknowledgement() throws {
        let legacyNoOp = makeWorkItem(state: .outcome(.noFixNeeded))
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: nil,
            state: .recoverable,
            syncSummary: nil,
            input: RecordInput(intent: .writeFixes, workItems: [legacyNoOp])
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        let item = try #require(detail.workItems.first)
        #expect(detail.canDismissItems)
        #expect(item.canDismiss)
        #expect(!item.isOpen)
    }

    @Test("a closed non-write run with failures offers no continuation")
    func closedObservationRunOffersNoContinuation() {
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: startDate.addingTimeInterval(10),
            state: .failed,
            syncSummary: nil,
            input: RecordInput(
                intent: .observeLibrary,
                writeTarget: writeTarget(),
                workItems: [makeWorkItem(state: .outcome(.failed))]
            )
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        #expect(!detail.canApplyRemainingFixes)
    }

    @Test("an open recovery run with failed work offers dismissal, not continuation")
    func openRecoveryRunOffersNoContinuation() {
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: nil,
            state: .recoverable,
            syncSummary: nil,
            input: RecordInput(
                intent: .writeFixes,
                writeTarget: writeTarget(),
                workItems: [makeWorkItem(state: .outcome(.failed)), makeWorkItem(state: .prepared)]
            )
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        #expect(!detail.canApplyRemainingFixes)
        #expect(detail.canDismissItems)
    }

    @Test("open item states stay open and attempting is write-uncertain")
    func openStatesAndUncertaintyMap() {
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: nil,
            state: .recoverable,
            syncSummary: nil,
            input: RecordInput(intent: .writeFixes, workItems: [
                makeWorkItem(state: .attempting),
                makeWorkItem(state: .attempted),
            ])
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        let allOpen = detail.workItems.allSatisfy(\.isOpen)
        let allUncertain = detail.workItems.allSatisfy(\.isWriteUncertain)
        #expect(allOpen)
        #expect(allUncertain)
        #expect(detail.workItems.map(\.stateLabel) == ["Attempting", "Attempted"])
    }

    @Test("album targets label the album and nil values render placeholders")
    func albumTargetAndPlaceholderLabels() {
        let albumItem = RunWorkItem(
            id: UUID(),
            target: .album(AlbumIdentity(artist: "Artist", album: "Album Title")),
            change: WorkChange(
                changeType: .yearUpdate,
                oldValue: nil,
                newValue: "1994",
                confidence: 90,
                source: "MusicBrainz"
            ),
            state: .prepared,
            detail: nil,
            dismissedAt: nil
        )
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: nil,
            state: .recoverable,
            syncSummary: nil,
            input: RecordInput(intent: .writeFixes, workItems: [albumItem])
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        #expect(detail.workItems[0].changeLabel == "Year: — → 1994 — Album Title")
    }

    @Test("failure detail never leaks into the dismissal audit slot")
    func failedItemDetailIsNotDismissedLabel() {
        let failed = makeWorkItem(state: .outcome(.failed), detail: "write timed out")
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: nil,
            state: .recoverable,
            syncSummary: nil,
            input: RecordInput(intent: .writeFixes, workItems: [failed, makeWorkItem(state: .prepared)])
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        #expect(detail.workItems[0].dismissedLabel == nil)
    }

    @Test("work items beyond the display cap collapse into a hidden count")
    func workItemsBeyondCapAreCounted() {
        let items = (0 ..< RunReportDetailBuilder.shownWorkItemLimit + 3).map { _ in
            makeWorkItem(state: .outcome(.written))
        }
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: startDate.addingTimeInterval(10),
            state: .completed,
            syncSummary: nil,
            input: RecordInput(intent: .writeFixes, workItems: items)
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        #expect(detail.workItems.count == RunReportDetailBuilder.shownWorkItemLimit)
        #expect(detail.hiddenWorkItemCount == 3)
    }

    @Test("prepared item IDs cover the full ledger, not just the display cap")
    func preparedItemIDsIgnoreDisplayCap() {
        let items = (0 ..< RunReportDetailBuilder.shownWorkItemLimit + 5).map { _ in
            makeWorkItem(state: .prepared)
        }
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: nil,
            state: .recoverable,
            syncSummary: nil,
            input: RecordInput(intent: .writeFixes, workItems: items)
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        #expect(detail.preparedItemIDs.count == items.count)
        #expect(detail.preparedItemIDs == items.map(\.id))
    }

    @Test("uncertain and closed items never enter the prepared set")
    func preparedItemIDsExcludeUncertainAndClosed() {
        let prepared = makeWorkItem(state: .prepared)
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: nil,
            state: .recoverable,
            syncSummary: nil,
            input: RecordInput(intent: .writeFixes, workItems: [
                prepared,
                makeWorkItem(state: .attempting),
                makeWorkItem(state: .attempted),
                makeWorkItem(state: .outcome(.failed)),
            ])
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        #expect(detail.preparedItemIDs == [prepared.id])
    }

    @Test("dismissed items surface their audit detail")
    func dismissedItemsSurfaceDetail() {
        let dismissed = RunWorkItem(
            id: UUID(),
            target: makeWorkItem(state: .prepared).target,
            change: makeWorkItem(state: .prepared).change,
            state: .outcome(.dismissed),
            detail: "Dismissed by user: duplicate",
            dismissedAt: Date(timeIntervalSince1970: 500)
        )
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: nil,
            state: .recoverable,
            syncSummary: nil,
            input: RecordInput(intent: .writeFixes, workItems: [dismissed, makeWorkItem(state: .prepared)])
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        #expect(detail.workItems[0].dismissedLabel == "Dismissed by user: duplicate")
        #expect(!detail.workItems[0].isOpen)
    }

    private struct RecordInput {
        var failureMessage: String?
        var scope: ProcessingScopeSnapshot?
        var intent: RunIntent = .observeLibrary
        var writeTarget: FixPlanWriteTarget?
        var continuesRunID: RunID?
        var writeSummary: RunWriteSummary?
        var workItems: [RunWorkItem] = []
    }

    private func makeRunRecord(
        startedAt: Date,
        finishedAt: Date?,
        state: RunLifecycleState,
        syncSummary: ActivitySyncSummary?,
        input: RecordInput = RecordInput()
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
            header: RunRecord.Header(
                runID: RunID(),
                requestID: RunRequestID(),
                trigger: .manualCheck,
                intent: input.intent,
                scope: input.scope ?? ProcessingScopeSnapshot.capture(
                    requestedTestArtists: [],
                    knownTrackCount: nil,
                    createdAt: startedAt,
                    reason: ""
                ),
                continuesRunID: input.continuesRunID,
                startedAt: startedAt
            ),
            writeTarget: input.writeTarget,
            transitions: transitions,
            workItems: input.workItems,
            status: RunRecord.Status(
                syncSummary: syncSummary,
                writeSummary: input.writeSummary,
                failureMessage: input.failureMessage,
                finishedAt: finishedAt
            )
        )
    }
}
