import Foundation
import Services
import Testing

@Suite("ReportsBuilder")
struct ReportsBuilderTests {
    private let startDate = Date(timeIntervalSince1970: 1_800_000_000)
    private let now = Date(timeIntervalSince1970: 1_800_000_480)

    @Test("empty page produces empty projection")
    func emptyPageProducesEmptyProjection() {
        let projection = makeProjection(records: [])

        #expect(projection.runs.isEmpty)
        #expect(projection.skippedCorruptedCount == 0)
        #expect(projection.revision == .initial)
    }

    @Test("empty projection preserves revision")
    func emptyProjectionPreservesRevision() {
        let projection = ReportsProjection.empty(revision: ProjectionRevision(7))

        #expect(projection.revision == ProjectionRevision(7))
        #expect(projection.runs.isEmpty)
        #expect(projection.skippedCorruptedCount == 0)
    }

    @Test("completed run maps index labels")
    func completedRunMapsIndexLabels() throws {
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: startDate.addingTimeInterval(45),
            state: .completed,
            syncSummary: ActivitySyncSummary(new: 2, modified: 1, identityChanged: 0, refreshed: 0, removed: 0)
        )

        let item = try #require(makeProjection(records: [record]).runs.first)

        #expect(item.id == record.runID.rawValue.uuidString)
        #expect(item.state == .completed)
        #expect(item.stateLabel == "Completed")
        #expect(item.triggerLabel == "Manual check")
        #expect(item.startedLabel == "8m ago")
        #expect(item.modeLabel == "Library check")
        #expect(item.scopeLabel == "Full library")
        #expect(item.durationLabel == "45s")
        #expect(item.changeCountLabel == "3 changes")
        #expect(item.failureSummary == nil)
    }

    @Test("completed no-op run maps no-changes labels")
    func completedNoOpRunMapsNoChangesLabels() throws {
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: startDate.addingTimeInterval(45),
            state: .completedNoOp,
            syncSummary: ActivitySyncSummary(new: 0, modified: 0, identityChanged: 0, refreshed: 0, removed: 0)
        )

        let item = try #require(makeProjection(records: [record]).runs.first)

        #expect(item.stateLabel == "Completed · no changes")
        #expect(item.changeCountLabel == "No changes")
    }

    @Test("preview no-op omits library delta from index labels")
    func previewHidesDelta() throws {
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: startDate.addingTimeInterval(45),
            state: .completedNoOp,
            syncSummary: ActivitySyncSummary(new: 2, modified: 3, identityChanged: 0, refreshed: 0, removed: 0),
            intent: .previewFixes
        )

        let item = try #require(makeProjection(records: [record]).runs.first)

        #expect(item.stateLabel == "Completed · no changes")
        #expect(item.changeCountLabel == nil)
    }

    @Test("single change uses singular label")
    func singleChangeUsesSingularLabel() throws {
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: startDate.addingTimeInterval(45),
            state: .completed,
            syncSummary: ActivitySyncSummary(new: 1, modified: 0, identityChanged: 0, refreshed: 0, removed: 0)
        )

        let item = try #require(makeProjection(records: [record]).runs.first)

        #expect(item.changeCountLabel == "1 change")
    }

    @Test("preview test-artist scope omits full-library track count")
    func mapsPreviewScope() throws {
        let record = makeRunRecord(
            scope: ProcessingScopeSnapshot.capture(
                requestedTestArtists: ["Aphex Twin", "Boards of Canada"],
                knownTrackCount: 44,
                createdAt: startDate,
                reason: "test"
            ),
            intent: .previewFixes
        )

        let item = try #require(makeProjection(records: [record]).runs.first)

        #expect(item.modeLabel == "Preview")
        #expect(item.scopeLabel == "Test artists (2)")
    }

    @Test("full library scope uses plural track count")
    func mapsFullLibrary() throws {
        let record = makeRunRecord(
            scope: ProcessingScopeSnapshot.capture(
                requestedTestArtists: [],
                knownTrackCount: 44,
                createdAt: startDate,
                reason: "test"
            ),
            intent: .observeLibrary
        )

        let item = try #require(makeProjection(records: [record]).runs.first)

        #expect(item.modeLabel == "Library check")
        #expect(item.scopeLabel == "Full library · 44 tracks")
    }

    @Test("test artist scope without track count omits count suffix")
    func mapsArtistScope() throws {
        let record = makeRunRecord(
            scope: ProcessingScopeSnapshot.capture(
                requestedTestArtists: ["Aphex Twin"],
                knownTrackCount: nil,
                createdAt: startDate,
                reason: "test"
            ),
            intent: .previewFixes
        )

        let item = try #require(makeProjection(records: [record]).runs.first)

        #expect(item.scopeLabel == "Test artists (1)")
    }

    @Test("write intent and singular scope count reach index labels")
    func mapsWriteScope() throws {
        let record = makeRunRecord(
            scope: ProcessingScopeSnapshot.capture(
                requestedTestArtists: [],
                knownTrackCount: 1,
                createdAt: startDate,
                reason: "test"
            ),
            intent: .writeFixes
        )

        let item = try #require(makeProjection(records: [record]).runs.first)

        #expect(item.modeLabel == "Auto-fix")
        #expect(item.scopeLabel == "Full library · 1 track")
    }

    @Test("failed run carries failure summary")
    func failedRunCarriesFailureSummary() {
        let recordWithMessage = makeRunRecord(
            startedAt: startDate,
            finishedAt: startDate.addingTimeInterval(45),
            state: .failed,
            syncSummary: nil,
            failureMessage: "Music.app unavailable"
        )
        let recordWithoutMessage = makeRunRecord(
            startedAt: startDate,
            finishedAt: startDate.addingTimeInterval(45),
            state: .failed,
            syncSummary: nil,
            failureMessage: nil
        )

        let items = makeProjection(records: [recordWithMessage, recordWithoutMessage]).runs

        #expect(items[0].failureSummary == "Music.app unavailable")
        #expect(items[1].failureSummary == "Run failed")
    }

    @Test("active run omits duration and changes")
    func activeRunOmitsDurationAndChanges() throws {
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: nil,
            state: .syncingLibrary,
            syncSummary: nil
        )

        let item = try #require(makeProjection(records: [record], activeRunID: record.runID).runs.first)

        #expect(item.state == .running)
        #expect(item.stateLabel == "In progress")
        #expect(item.durationLabel == nil)
        #expect(item.changeCountLabel == nil)
    }

    @Test("open persisted run maps to recovery needed")
    func openRunRecovery() throws {
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: nil,
            state: .reporting,
            syncSummary: nil
        )

        let item = try #require(makeProjection(records: [record]).runs.first)

        #expect(item.state == .recoveryNeeded)
        #expect(item.stateLabel == "Recovery needed")
        #expect(item.durationLabel == nil)
        #expect(item.changeCountLabel == nil)
        #expect(item.failureSummary == "Previous run needs recovery")
    }

    @Test("reporting state maps to running")
    func reportingStateMapsToRunning() throws {
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: nil,
            state: .reporting,
            syncSummary: nil
        )

        let item = try #require(makeProjection(records: [record], activeRunID: record.runID).runs.first)

        #expect(item.state == .running)
        #expect(item.stateLabel == "In progress")
    }

    @Test("planning fixes state maps to running")
    func planningFixesStateMapsToRunning() throws {
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: nil,
            state: .planningFixes,
            syncSummary: nil
        )

        let item = try #require(makeProjection(records: [record], activeRunID: record.runID).runs.first)

        #expect(item.state == .running)
        #expect(item.stateLabel == "In progress")
    }

    @Test("canonical lifecycle states map to report labels")
    func mapsCanonicalLifecycleLabels() throws {
        let cases: [(RunLifecycleState, ReportsRunState, String)] = [
            (.queued, .running, "In progress"),
            (.analyzingDelta, .running, "In progress"),
            (.awaitingReview, .awaitingReview, "Awaiting review"),
            (.writing, .running, "In progress"),
            (.verifying, .running, "In progress"),
            (.blocked, .blocked, "Blocked"),
            (.cancelled, .cancelled, "Cancelled"),
            (.recoverable, .recoveryNeeded, "Recovery needed"),
            (.recovering, .running, "In progress")
        ]

        for (lifecycleState, runState, stateLabel) in cases {
            let record = makeRunRecord(
                startedAt: startDate,
                finishedAt: startDate.addingTimeInterval(45),
                state: lifecycleState,
                syncSummary: nil
            )
            let item = try #require(makeProjection(records: [record]).runs.first)

            #expect(item.state == runState)
            #expect(item.stateLabel == stateLabel)
        }
    }

    @Test("open review and blocked states do not become recovery needed")
    func keepsOpenReviewBlockedLabels() {
        let records = [
            makeRunRecord(startedAt: startDate, finishedAt: nil, state: .awaitingReview, syncSummary: nil),
            makeRunRecord(startedAt: startDate, finishedAt: nil, state: .blocked, syncSummary: nil)
        ]

        let items = makeProjection(records: records).runs

        #expect(items.map(\.state) == [.awaitingReview, .blocked])
        #expect(items.map(\.stateLabel) == ["Awaiting review", "Blocked"])
    }

    @Test(
        "trigger labels cover all triggers",
        arguments: zip(
            [RunTrigger.manualCheck, .backgroundSync, .fileSystemEvent, .recovery],
            ["Manual check", "Background sync", "File system event", "Recovery"]
        )
    )
    func triggerLabelsCoverAllTriggers(trigger: RunTrigger, expectedLabel: String) throws {
        let record = makeRunRecord(
            trigger: trigger,
            startedAt: startDate,
            finishedAt: startDate.addingTimeInterval(45),
            state: .completed,
            syncSummary: nil
        )

        let item = try #require(makeProjection(records: [record]).runs.first)

        #expect(item.triggerLabel == expectedLabel)
    }

    @Test(
        "duration label formats minute and hour buckets",
        arguments: zip(
            [59, 60, 200, 3599, 3600, 4500],
            ["59s", "1m", "3m 20s", "59m 59s", "1h", "1h 15m"]
        )
    )
    func durationLabelFormatsMinuteAndHourBuckets(seconds: Int, expectedLabel: String) throws {
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: startDate.addingTimeInterval(TimeInterval(seconds)),
            state: .completed,
            syncSummary: nil
        )

        let item = try #require(makeProjection(records: [record]).runs.first)

        #expect(item.durationLabel == expectedLabel)
    }

    @Test(
        "started label formats relative buckets",
        arguments: zip(
            [
                TimeInterval(0), TimeInterval(59), TimeInterval(60), TimeInterval(300),
                TimeInterval(3599), TimeInterval(3600), TimeInterval(3 * 3600),
                TimeInterval(86399), TimeInterval(86400), TimeInterval(2 * 86400)
            ],
            ["just now", "just now", "1m ago", "5m ago", "59m ago", "1h ago", "3h ago", "23h ago", "1d ago", "2d ago"]
        )
    )
    func startedLabelFormatsRelativeBuckets(elapsed: TimeInterval, expectedLabel: String) throws {
        let record = makeRunRecord(
            startedAt: startDate,
            finishedAt: nil,
            state: .syncingLibrary,
            syncSummary: nil
        )

        let projection = ReportsBuilder.makeProjection(
            from: ReportsProjectionInput(
                records: [record],
                skippedCorruptedCount: 0,
                now: startDate.addingTimeInterval(elapsed)
            )
        )
        let item = try #require(projection.runs.first)

        #expect(item.startedLabel == expectedLabel)
    }

    @Test("skipped corrupted count passes through")
    func skippedCorruptedCountPassesThrough() {
        let projection = makeProjection(records: [], skippedCorruptedCount: 2)

        #expect(projection.skippedCorruptedCount == 2)
    }

    @Test("records keep store order")
    func recordsKeepStoreOrder() {
        let first = makeRunRecord(startedAt: startDate, finishedAt: nil, state: .syncingLibrary, syncSummary: nil)
        let second = makeRunRecord(
            startedAt: startDate.addingTimeInterval(-100),
            finishedAt: nil,
            state: .syncingLibrary,
            syncSummary: nil
        )

        let projection = makeProjection(records: [first, second])

        #expect(projection.runs.map(\.id) == [first.runID.rawValue.uuidString, second.runID.rawValue.uuidString])
    }

    private func makeProjection(
        records: [RunRecord],
        skippedCorruptedCount: Int = 0,
        activeRunID: RunID? = nil
    ) -> ReportsProjection {
        ReportsBuilder.makeProjection(
            from: ReportsProjectionInput(
                records: records,
                skippedCorruptedCount: skippedCorruptedCount,
                now: now,
                activeRunID: activeRunID
            )
        )
    }

    private func makeRunRecord(
        trigger: RunTrigger = .manualCheck,
        startedAt: Date,
        finishedAt: Date?,
        state: RunLifecycleState,
        syncSummary: ActivitySyncSummary?,
        failureMessage: String? = nil,
        intent: RunIntent = .observeLibrary
    ) -> RunRecord {
        var transitions = [
            RunLifecycleTransition(state: .created, timestamp: startedAt),
            RunLifecycleTransition(state: .syncingLibrary, timestamp: startedAt.addingTimeInterval(1))
        ]
        if state != .syncingLibrary {
            transitions.append(RunLifecycleTransition(
                state: state,
                timestamp: finishedAt ?? startedAt.addingTimeInterval(2)
            ))
        }

        return RunRecord(
            runID: RunID(),
            requestID: RunRequestID(),
            trigger: trigger,
            intent: intent,
            scope: ProcessingScopeSnapshot.capture(
                requestedTestArtists: [],
                knownTrackCount: nil,
                createdAt: startedAt,
                reason: "test"
            ),
            transitions: transitions,
            syncSummary: syncSummary,
            failureMessage: failureMessage,
            startedAt: startedAt,
            finishedAt: finishedAt
        )
    }

    private func makeRunRecord(scope: ProcessingScopeSnapshot, intent: RunIntent) -> RunRecord {
        RunRecord(
            runID: RunID(),
            requestID: RunRequestID(),
            trigger: .manualCheck,
            intent: intent,
            scope: scope,
            transitions: [
                RunLifecycleTransition(state: .created, timestamp: startDate),
                RunLifecycleTransition(state: .completed, timestamp: startDate.addingTimeInterval(45))
            ],
            syncSummary: nil,
            failureMessage: nil,
            startedAt: startDate,
            finishedAt: startDate.addingTimeInterval(45)
        )
    }
}
