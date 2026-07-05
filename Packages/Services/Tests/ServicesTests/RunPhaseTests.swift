import Core
import Foundation
import Services
import Testing

@Suite("RunPhase intent transitions")
struct RunPhaseTests {
    private let startedAt = Date(timeIntervalSince1970: 100)
    private let finishedAt = Date(timeIntervalSince1970: 160)

    @Test("phase maps to wire state for every case")
    func phaseMapsToWireStateForEveryCase() {
        let result = SyncResult()

        #expect(RunPhase.active(.created).state == .created)
        #expect(RunPhase.active(.syncingLibrary).state == .syncingLibrary)
        #expect(RunPhase.active(.reporting).state == .reporting)
        #expect(RunPhase.finished(.completed(result), finishedAt: finishedAt).state == .completed)
        #expect(RunPhase.finished(.completedNoOp(result), finishedAt: finishedAt).state == .completedNoOp)
        #expect(RunPhase.finished(.failed(message: "boom"), finishedAt: finishedAt).state == .failed)
    }

    @Test("happy path walk finishes as completed with the sync result")
    func happyPathWalkFinishesAsCompleted() {
        let result = SyncResult(newTracks: [
            Track(id: "NEW", name: "Track", artist: "Artist", album: "Album")
        ])
        let created = makeCreatedSnapshot()

        let syncing = created.beginningSync()
        #expect(syncing.phase == .active(.syncingLibrary))
        #expect(syncing.state == .syncingLibrary)
        #expect(syncing.isActive)
        #expect(syncing.finishedAt == nil)
        #expect(syncing.syncResult == nil)
        #expect(syncing.failureMessage == nil)

        let reporting = syncing.beginningReporting()
        #expect(reporting.phase == .active(.reporting))
        #expect(reporting.isActive)

        let completed = reporting.finishing(result: result, at: finishedAt)
        #expect(completed.phase == .finished(.completed(result), finishedAt: finishedAt))
        #expect(completed.state == .completed)
        #expect(!completed.isActive)
        #expect(completed.finishedAt == finishedAt)
        #expect(completed.syncResult == result)
        #expect(completed.failureMessage == nil)
        #expect(completed.runID == created.runID)
        #expect(completed.startedAt == created.startedAt)
    }

    @Test("finishing with a no-change result finishes as completedNoOp")
    func finishingWithNoChangeResultFinishesAsCompletedNoOp() {
        let result = SyncResult()
        let reporting = makeCreatedSnapshot().beginningSync().beginningReporting()

        let completed = reporting.finishing(result: result, at: finishedAt)

        #expect(completed.phase == .finished(.completedNoOp(result), finishedAt: finishedAt))
        #expect(completed.state == .completedNoOp)
        #expect(completed.syncResult == result)
        #expect(completed.finishedAt == finishedAt)
    }

    @Test("failing from an active phase records the failure payload")
    func failingFromActivePhaseRecordsFailurePayload() {
        let syncing = makeCreatedSnapshot().beginningSync()

        let failed = syncing.failing(message: "Music.app unavailable", at: finishedAt)

        #expect(failed.phase == .finished(.failed(message: "Music.app unavailable"), finishedAt: finishedAt))
        #expect(failed.state == .failed)
        #expect(!failed.isActive)
        #expect(failed.failureMessage == "Music.app unavailable")
        #expect(failed.finishedAt == finishedAt)
        #expect(failed.syncResult == nil)
    }

    private func makeCreatedSnapshot() -> RunLifecycleSnapshot {
        RunLifecycleSnapshot(
            runID: RunID(),
            requestID: RunRequestID(),
            trigger: .manualCheck,
            intent: .observeLibrary,
            scope: ProcessingScopeSnapshot.capture(
                requestedTestArtists: [],
                knownTrackCount: 75,
                createdAt: startedAt,
                reason: "manualCheck"
            ),
            startedAt: startedAt,
            phase: .active(.created)
        )
    }
}
