import Core
import Foundation
import Testing
@testable import Services

@Suite("Recovery report detail")
struct RecoveryReportDetailTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_480)

    @Test("an observed no-op offers one acknowledgement without pretending to be open")
    func observedNoOpOffersAcknowledgement() throws {
        let noOp = makeWorkItem(state: .outcome(.noFixNeeded))
        let record = try makeRecoveryRecord(workItems: [noOp]).recordingRecoveryObservationBlocker(
            RecoveryObservationBlocker(itemID: noOp.id, issue: .trackMissing)
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        let item = try #require(detail.workItems.first)
        #expect(detail.canDismissItems)
        #expect(item.canDismiss)
        #expect(!item.isOpen)
        #expect(item.attentionLabel == "The track is no longer available in Music.app")
    }

    @Test("an unobserved no-op does not offer an ambiguous acknowledgement")
    func unobservedNoOpHasNoAcknowledgement() throws {
        let noOp = makeWorkItem(state: .outcome(.noFixNeeded))
        let detail = RunReportDetailBuilder.makeDetail(
            from: makeRecoveryRecord(workItems: [noOp]),
            now: now
        )

        let item = try #require(detail.workItems.first)
        #expect(!detail.canDismissItems)
        #expect(!item.canDismiss)
        #expect(item.attentionLabel == nil)
    }

    @Test("an acknowledgement blocker remains visible beyond the ordinary item cap")
    func blockerRemainsVisibleBeyondCap() throws {
        let ordinaryItems = (0 ..< RunReportDetailBuilder.shownWorkItemLimit).map { index in
            makeWorkItem(id: UUID(), state: .outcome(index.isMultiple(of: 2) ? .skipped : .failed))
        }
        let blocker = makeWorkItem(state: .outcome(.noFixNeeded))
        let record = try makeRecoveryRecord(
            workItems: ordinaryItems + [blocker]
        ).recordingRecoveryObservationBlocker(
            RecoveryObservationBlocker(itemID: blocker.id, issue: .trackIdentityChanged)
        )

        let detail = RunReportDetailBuilder.makeDetail(from: record, now: now)

        let projectedBlocker = try #require(detail.workItems.first(where: { $0.id == blocker.id }))
        #expect(detail.workItems.count == RunReportDetailBuilder.shownWorkItemLimit + 1)
        #expect(detail.hiddenWorkItemCount == 0)
        #expect(projectedBlocker.canDismiss)
        #expect(projectedBlocker.attentionLabel == "Music.app now associates this database ID with a different track")
    }

    private func makeRecoveryRecord(workItems: [RunWorkItem]) -> RunRecord {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        return RunRecord(
            header: RunRecord.Header(
                runID: RunID(),
                requestID: RunRequestID(),
                trigger: .manualCheck,
                intent: .writeFixes,
                scope: ProcessingScopeSnapshot.capture(
                    requestedTestArtists: [],
                    knownTrackCount: nil,
                    createdAt: startedAt,
                    reason: ""
                ),
                continuesRunID: nil,
                startedAt: startedAt
            ),
            transitions: [
                RunLifecycleTransition(state: .created, timestamp: startedAt),
                RunLifecycleTransition(state: .recoverable, timestamp: startedAt.addingTimeInterval(1)),
            ],
            workItems: workItems,
            status: RunRecord.Status(
                syncSummary: nil,
                failureMessage: nil,
                finishedAt: nil
            )
        )
    }
}
