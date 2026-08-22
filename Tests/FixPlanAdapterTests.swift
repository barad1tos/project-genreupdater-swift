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

        let snapshot = FixPlanAdapter.makeSnapshot(
            from: projection,
            hasCleaningAccess: true
        )

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
        #expect(snapshot.writeAccess == .available)
        #expect(snapshot.issues == ["Notice: Stored fallback was used"])
        #expect(snapshot.items.first?.id == itemID.uuidString)
        #expect(snapshot.items.first?.type == DesignUI.ChangeType.year)
        #expect(snapshot.items.first?.confidence == 0.91)
        #expect(snapshot.items.first?.verdict == .accepted)
        #expect(snapshot.items.map(\.hasWriteID) == [false, true])
    }

    @Test("accepted cleaning locks apply without paid access")
    func locksAcceptedCleaning() throws {
        let projection = try makeCleaningProjection(verdict: .accepted)

        let snapshot = FixPlanAdapter.makeSnapshot(
            from: projection,
            hasCleaningAccess: false
        )

        #expect(snapshot.writeAccess == .locked(message: UpgradeCopy.cleaningWrite))
        #expect(snapshot.canApply)
    }

    @Test("rejected cleaning does not require paid access")
    func ignoresRejectedCleaning() throws {
        let projection = try makeCleaningProjection(verdict: .rejected)

        let snapshot = FixPlanAdapter.makeSnapshot(
            from: projection,
            hasCleaningAccess: false
        )

        #expect(snapshot.writeAccess == .available)
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
            scope: nil,
            summary: FixPlanProjection.Summary(
                itemCount: 2,
                acceptedCount: 2,
                rejectedCount: 0,
                genreCount: 0,
                yearCount: 2,
                trackCleaningCount: 0,
                albumCleaningCount: 0,
                artistRenameCount: 0,
                affectedTrackCount: 2,
                affectedAlbumCount: 1,
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
                trackID: id.uuidString,
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

    private func makeCleaningProjection(verdict: FixPlanItemVerdict) throws -> FixPlanProjection {
        let itemID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
        let acceptedCount = verdict == .accepted ? 1 : 0
        return FixPlanProjection(
            revision: ProjectionRevision(1),
            status: .ready,
            lineage: FixPlanProjection.Lineage(
                planID: FixPlanID(),
                planRevision: .initial,
                decisionRevision: .initial,
                sourceRunID: RunID()
            ),
            scope: nil,
            summary: FixPlanProjection.Summary(
                itemCount: 1,
                acceptedCount: acceptedCount,
                rejectedCount: 1 - acceptedCount,
                genreCount: 0,
                yearCount: 0,
                trackCleaningCount: 1,
                albumCleaningCount: 0,
                artistRenameCount: 0,
                affectedTrackCount: 1,
                affectedAlbumCount: 1,
                averageConfidence: 90,
                canApply: acceptedCount > 0
            ),
            stalenessReasons: [],
            items: [
                FixPlanProjectionItem(
                    id: itemID,
                    identity: FixPlanProjectionItem.Identity(
                        trackID: itemID.uuidString,
                        trackName: "Song (Remastered)",
                        artist: "Artist",
                        album: "Album"
                    ),
                    change: FixPlanProjectionItem.Change(
                        type: .trackCleaning,
                        oldValue: "Song (Remastered)",
                        newValue: "Song",
                        confidence: 90,
                        source: "cleaner"
                    ),
                    verdict: verdict,
                    hasWriteID: true
                ),
            ],
            operationalIssues: []
        )
    }
}
