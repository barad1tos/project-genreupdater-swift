import Core
import DesignUI
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("UpdateResultPreviewAdapter")
struct UpdateResultPreviewAdapterTests {
    @Test("maps a captured fix plan into the complete preview hierarchy")
    func mapsProjection() throws {
        let projection = try makeProjection()

        let snapshot = UpdateResultPreviewAdapter.makeSnapshot(
            from: projection,
            hasCleaningAccess: true
        )

        #expect(snapshot.mode == .preview)
        #expect(snapshot.status == .ready)
        #expect(snapshot.scope == "Test Artists: 2")
        #expect(snapshot.albums.map(\.title) == ["Björk — Homogenic", "Björk — Post"])
        #expect(snapshot.affectedTrackCount == projection.affectedTrackCount)

        let metrics = Dictionary(uniqueKeysWithValues: snapshot.metrics.map { ($0.id, $0.value) })
        #expect(metrics == [
            "changes": "5",
            "accepted": "4",
            "rejected": "1",
            "genre": "1",
            "year": "1",
            "track-cleaning": "1",
            "album-cleaning": "1",
            "artist-rename": "1",
            "affected-tracks": "3",
            "affected-albums": "2",
            "average-confidence": "91%",
        ])

        let tracks = snapshot.albums.flatMap(\.tracks)
        #expect(tracks.map(\.id) == ["t3", "t1", "t2"])
        #expect(tracks.first?.changes.count == 2)
        #expect(tracks.allSatisfy { $0.state == .ready })

        let changes = tracks.flatMap(\.changes)
        #expect(Set(changes.map(\.id)) == Set(proposalIDs.map(\.uuidString)))
        #expect(changes.first?.state == .proposed(.accepted))
        #expect(changes.first?.source == "MusicBrainz")
        #expect(changes.first?.confidence == 0.91)
        #expect(changes.map(\.type) == [.album, .artist, .genre, .revert, .track])
        #expect(snapshot.notices.contains { $0.id == "fix-plan-write-identity" })
        #expect(snapshot.notices
            .contains { $0.message == "Write identity required: Accepted items without AppleScript ID: 1" })
    }

    @Test("maps every projection availability state")
    func mapsStatuses() throws {
        let ready = try makeProjection(status: .ready)

        #expect(UpdateResultPreviewAdapter.makeSnapshot(from: ready, hasCleaningAccess: true).status == .ready)
        #expect(UpdateResultPreviewAdapter.makeSnapshot(
            from: ready.withStatus(.stale),
            hasCleaningAccess: true
        ).status == .stale)
        #expect(UpdateResultPreviewAdapter.makeSnapshot(
            from: ready.withStatus(.unavailable),
            hasCleaningAccess: true
        ).status == .unavailable)
        #expect(UpdateResultPreviewAdapter.makeSnapshot(
            from: .empty(),
            hasCleaningAccess: true
        ).status == .empty)
    }

    @Test("accepted cleaning locks primary action without paid access")
    func locksAcceptedCleaning() throws {
        let projection = try makeCleaningProjection(verdict: .accepted)

        let snapshot = UpdateResultPreviewAdapter.makeSnapshot(
            from: projection,
            hasCleaningAccess: false
        )

        #expect(snapshot.contentAccess == .locked(message: UpgradeCopy.cleaningWrite))
    }

    @Test("rejected cleaning remains reviewable without paid access")
    func ignoresRejectedCleaning() throws {
        let projection = try makeCleaningProjection(verdict: .rejected)

        let snapshot = UpdateResultPreviewAdapter.makeSnapshot(
            from: projection,
            hasCleaningAccess: false
        )

        #expect(snapshot.contentAccess == .available)
    }

    @Test("maps legacy changes through real track and proposal identities")
    func mapsLegacyChanges() throws {
        let acceptedID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000011"))
        let rejectedID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000012"))
        let track = Track(
            id: "legacy-track",
            name: "Jóga",
            artist: "Björk",
            album: "Homogenic"
        )
        let changes = [
            ProposedChange(
                id: acceptedID,
                track: track,
                changeType: .genreUpdate,
                oldValue: "Electronic",
                newValue: "Electronica",
                confidence: 125,
                source: "Discogs"
            ),
            ProposedChange(
                id: rejectedID,
                track: track,
                changeType: .yearUpdate,
                oldValue: nil,
                newValue: "1997",
                confidence: -5,
                source: "MusicBrainz",
                isAccepted: false
            ),
        ]

        let snapshot = UpdateResultPreviewAdapter.makeSnapshot(
            changes: changes,
            scopeTitle: "Smart Filter - Missing Genres",
            hasCleaningAccess: true,
            primaryActionLabel: "Enable Writes"
        )

        let resultTrack = try #require(snapshot.albums.first?.tracks.first)
        #expect(snapshot.mode == .preview)
        #expect(snapshot.scope == "Smart Filter - Missing Genres")
        #expect(snapshot.primaryActionLabel == "Enable Writes")
        #expect(resultTrack.id == track.id)
        #expect(resultTrack.changes.map(\.id) == [acceptedID.uuidString, rejectedID.uuidString])
        #expect(resultTrack.changes.map(\.state) == [.proposed(.accepted), .proposed(.rejected)])
        #expect(resultTrack.changes.map(\.confidence) == [1, 0])
    }

    @MainActor
    @Test("shared result view retains the optional locked-access action")
    func retainsAccessAction() throws {
        let snapshot = try UpdateResultPreviewAdapter.makeSnapshot(
            from: makeCleaningProjection(verdict: .accepted),
            hasCleaningAccess: false
        )
        var actionCount = 0

        let view = UpdateResultView(
            snapshot: snapshot,
            onAccessAction: { actionCount += 1 }
        )
        view.onAccessAction?()

        #expect(actionCount == 1)
    }
}

private let proposalIDs = [
    "00000000-0000-0000-0000-000000000001",
    "00000000-0000-0000-0000-000000000002",
    "00000000-0000-0000-0000-000000000003",
    "00000000-0000-0000-0000-000000000004",
    "00000000-0000-0000-0000-000000000005",
].compactMap(UUID.init(uuidString:))

private func makeProjection(
    status: FixPlanProjectionStatus = .ready
) throws -> FixPlanProjection {
    let items = [
        makeItem(index: 0, trackID: "t1", album: "Post", type: .genreUpdate, hasWriteID: false),
        makeItem(index: 1, trackID: "t1", album: "Post", type: .yearRevert, verdict: .rejected),
        makeItem(index: 2, trackID: "t2", album: "Post", type: .trackCleaning),
        makeItem(index: 3, trackID: "t3", album: "Homogenic", type: .albumCleaning),
        makeItem(index: 4, trackID: "t3", album: "Homogenic", type: .artistRename),
    ]
    return FixPlanProjection(
        revision: ProjectionRevision(2),
        status: status,
        lineage: FixPlanProjection.Lineage(
            planID: FixPlanID(),
            planRevision: FixPlanRevision(3),
            decisionRevision: ReviewDecisionRevision(4),
            sourceRunID: RunID()
        ),
        scope: ProcessingScopeSnapshot(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: .testArtists,
            normalizedTestArtists: ["Björk", "Aphex Twin"],
            matchingRule: "test",
            knownTrackCount: 3,
            fingerprint: "test",
            reason: "unit-test"
        ),
        summary: FixPlanProjection.Summary(
            itemCount: 5,
            acceptedCount: 4,
            rejectedCount: 1,
            genreCount: 1,
            yearCount: 1,
            trackCleaningCount: 1,
            albumCleaningCount: 1,
            artistRenameCount: 1,
            affectedTrackCount: 3,
            affectedAlbumCount: 2,
            averageConfidence: 91,
            canApply: false
        ),
        stalenessReasons: status == .stale ? [.configurationChanged] : [],
        items: items,
        operationalIssues: [
            OperationalIssue(
                id: "fix-plan-write-identity",
                category: .safetyBlocked,
                summary: "Write identity required",
                technicalDetail: "Accepted items without AppleScript ID: 1"
            ),
        ]
    )
}

private func makeItem(
    index: Int,
    trackID: String,
    album: String,
    type: Core.ChangeType,
    verdict: FixPlanItemVerdict = .accepted,
    hasWriteID: Bool = true
) -> FixPlanProjectionItem {
    FixPlanProjectionItem(
        id: proposalIDs[index],
        identity: FixPlanProjectionItem.Identity(
            trackID: trackID,
            trackName: "Track " + trackID,
            artist: "Björk",
            album: album
        ),
        change: FixPlanProjectionItem.Change(
            type: type,
            oldValue: "old",
            newValue: "new",
            confidence: 91,
            source: "MusicBrainz"
        ),
        verdict: verdict,
        hasWriteID: hasWriteID
    )
}

private func makeCleaningProjection(verdict: FixPlanItemVerdict) throws -> FixPlanProjection {
    let projection = try makeProjection()
    let cleaningItem = makeItem(
        index: 2,
        trackID: "t2",
        album: "Post",
        type: .trackCleaning,
        verdict: verdict
    )
    let acceptedCount = verdict == .accepted ? 1 : 0
    return FixPlanProjection(
        revision: .initial,
        status: .ready,
        lineage: projection.lineage,
        scope: projection.scope,
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
            averageConfidence: 91,
            canApply: acceptedCount > 0
        ),
        stalenessReasons: [],
        items: [cleaningItem],
        operationalIssues: []
    )
}

extension FixPlanProjection {
    fileprivate func withStatus(_ status: FixPlanProjectionStatus) -> Self {
        Self(
            revision: revision,
            status: status,
            lineage: lineage,
            scope: scope,
            summary: summary,
            stalenessReasons: status == .stale ? [.configurationChanged] : [],
            items: items,
            operationalIssues: operationalIssues
        )
    }
}
