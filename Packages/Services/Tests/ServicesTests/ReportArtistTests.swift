import Core
import Foundation
import Testing
@testable import Services

@Suite("Coupled artist report projection")
struct ReportArtistTests {
    @Test("Work item labels disclose coupled album artist changes")
    func coupledArtistEffectIsVisible() {
        let detail = makeDetail(writeChange: nil)

        #expect(detail.workItems[0].changeLabel.contains(
            "Massive (album artist: Massive) → Massive Attack (album artist: Massive Attack)"
        ))
    }

    @Test("Work item labels use the reconciled write effect")
    func reconciledArtistEffectIsVisible() {
        let detail = makeDetail(writeChange: WorkChange(
            changeType: .artistRename,
            oldValue: "Massive",
            newValue: "Massive Attack",
            confidence: 100,
            source: "Artist mappings"
        ))

        #expect(detail.workItems[0].changeLabel.contains("Artist: Massive → Massive Attack"))
        #expect(!detail.workItems[0].changeLabel.contains("album artist"))
    }

    private func makeDetail(writeChange: WorkChange?) -> RunReportDetailProjection {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let workItem = RunWorkItem(
            id: UUID(),
            target: .track(FixPlanItemIdentity(
                readID: "T1",
                appleScriptID: "AS1",
                artist: "Massive Attack",
                album: "Mezzanine",
                trackName: "Teardrop",
                albumArtist: "Massive Attack"
            )),
            change: WorkChange(
                changeType: .artistRename,
                oldValue: "Massive",
                newValue: "Massive Attack",
                confidence: 100,
                source: "Artist mappings",
                albumArtistChange: AlbumArtistChange(oldValue: "Massive", newValue: "Massive Attack")
            ),
            state: .attempting,
            writeChange: writeChange
        )
        let record = RunRecord(
            header: RunRecord.Header(
                runID: RunID(),
                requestID: RunRequestID(),
                trigger: .manualCheck,
                intent: .writeFixes,
                scope: ProcessingScopeSnapshot.capture(
                    requestedTestArtists: [],
                    knownTrackCount: 1,
                    createdAt: startedAt,
                    reason: "report-test"
                ),
                continuesRunID: nil,
                startedAt: startedAt
            ),
            transitions: [
                RunLifecycleTransition(state: .created, timestamp: startedAt),
                RunLifecycleTransition(state: .writing, timestamp: startedAt.addingTimeInterval(1)),
            ],
            workItems: [workItem],
            status: RunRecord.Status(
                syncSummary: nil,
                failureMessage: nil,
                finishedAt: nil
            )
        )

        return RunReportDetailBuilder.makeDetail(
            from: record,
            now: startedAt.addingTimeInterval(10)
        )
    }
}
