import Core
import DesignUI
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("FixPlanAdapter")
struct FixPlanAdapterTests {
    @Test("maps projection to design snapshot")
    func mapsProjection() throws {
        let (projection, itemID) = try makeProjection()

        let snapshot = FixPlanAdapter.makeSnapshot(from: projection)

        #expect(snapshot.status == .ready)
        #expect(snapshot.planID == projection.planID?.description)
        #expect(snapshot.planRevision == 3)
        #expect(snapshot.decisionRevision == 4)
        #expect(snapshot.projectionRevision == 2)
        #expect(snapshot.itemCount == 2)
        #expect(snapshot.acceptedCount == 2)
        #expect(snapshot.yearCount == 2)
        #expect(snapshot.averageConfidence == 91)
        #expect(snapshot.canApply)
        #expect(snapshot.issues == ["Notice: Stored fallback was used"])
        #expect(snapshot.items.first?.id == itemID.uuidString)
        #expect(snapshot.items.first?.type == DesignUI.ChangeType.year)
        #expect(snapshot.items.first?.confidence == 0.91)
        #expect(snapshot.items.first?.verdict == .accepted)
        #expect(snapshot.items.map(\.hasWriteID) == [false, true])
    }

    private func makeProjection() throws -> (FixPlanProjection, UUID) {
        let itemID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondItemID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let projection = FixPlanProjection(
            revision: ProjectionRevision(2),
            status: .ready,
            lineage: FixPlanProjection.Lineage(
                planID: FixPlanID(),
                planRevision: FixPlanRevision(3),
                decisionRevision: ReviewDecisionRevision(4),
                sourceRunID: RunID()
            ),
            summary: FixPlanProjection.Summary(
                itemCount: 2,
                acceptedCount: 2,
                rejectedCount: 0,
                genreCount: 0,
                yearCount: 2,
                averageConfidence: 91,
                canApply: true
            ),
            stalenessReasons: [],
            items: [
                makeItem(id: itemID, hasWriteID: false),
                makeItem(id: secondItemID, hasWriteID: true)
            ],
            operationalIssues: [
                OperationalIssue(
                    id: "notice",
                    category: .temporaryUnavailable,
                    summary: "Notice",
                    technicalDetail: "Stored fallback was used"
                )
            ]
        )
        return (projection, itemID)
    }

    private func makeItem(id: UUID, hasWriteID: Bool) -> FixPlanProjectionItem {
        FixPlanProjectionItem(
            id: id,
            identity: FixPlanProjectionItem.Identity(
                trackName: "Idioteque",
                artist: "Radiohead",
                album: "Kid A"
            ),
            change: FixPlanProjectionItem.Change(
                type: Core.ChangeType.yearUpdate,
                oldValue: nil,
                newValue: "2000",
                confidence: 91,
                source: "MusicBrainz"
            ),
            verdict: .accepted,
            hasWriteID: hasWriteID
        )
    }
}
