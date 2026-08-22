import Core
import Foundation
import Services
import Testing
@testable import DesignUI
@testable import Genre_Updater

@Suite("UpdateResultPreviewAdapter")
struct UpdateResultPreviewAdapterTests {
    @Test("maps a captured fix plan into the complete preview hierarchy")
    func mapsProjection() throws {
        let projection = try makeProjection()

        let snapshot = UpdateResultPreviewAdapter.makeSnapshot(
            from: projection,
            hasCleaningAccess: true,
            noticeMessage: nil,
            noticeTone: .info
        )

        #expect(snapshot.mode == .preview)
        #expect(snapshot.status == .ready)
        #expect(snapshot.scope == "Test Artists: 2")
        #expect(snapshot.albums.map(\.title) == ["Björk — Homogenic", "Björk — Post"])
        let metrics = Dictionary(uniqueKeysWithValues: snapshot.metrics.map { ($0.id, $0.value) })
        #expect(metrics == [
            "changes": "6",
            "accepted": "5",
            "rejected": "1",
            "genre": "1",
            "year": "2",
            "track-cleaning": "1",
            "album-cleaning": "1",
            "artist-rename": "1",
            "affected-tracks": "4",
            "affected-albums": "2",
            "average-confidence": "91%",
        ])

        let tracks = snapshot.albums.flatMap(\.tracks)
        #expect(tracks.map(\.id) == ["t3", "t4", "t1", "t2"])
        #expect(tracks.first?.changes.count == 2)
        #expect(tracks.allSatisfy { $0.state == .ready })

        let changes = tracks.flatMap(\.changes)
        #expect(Set(changes.map(\.id)) == Set(proposalIDs.map(\.uuidString)))
        #expect(changes.allSatisfy { change in
            if case .proposed = change.state {
                return true
            }
            return false
        })
        #expect(changes.first?.state == .proposed(.accepted))
        #expect(changes.first?.source == "MusicBrainz")
        #expect(changes.first?.confidence == 0.91)
        #expect(changes.map(\.type) == [.album, .artist, .year, .genre, .revert, .track])
        #expect(snapshot.notices.contains { $0.id == "fix-plan-write-identity" })
        #expect(snapshot.notices
            .contains { $0.message == "Write identity required: Accepted items without AppleScript ID: 1" })
        let identityNotice = try #require(snapshot.notices.first {
            $0.id == "missing-write-id-00000000-0000-0000-0000-000000000001"
        })
        #expect(identityNotice.title == "Write identity required")
        #expect(identityNotice.message == """
        Proposal 00000000-0000-0000-0000-000000000001 for track t1 cannot be applied because its AppleScript write \
        identity is missing.
        """)
    }

    @Test("maps every projection availability state")
    func mapsStatuses() throws {
        let ready = try makeProjection(status: .ready)

        #expect(UpdateResultPreviewAdapter.makeSnapshot(
            from: ready,
            hasCleaningAccess: true,
            noticeMessage: nil,
            noticeTone: .info
        ).status == .ready)
        #expect(UpdateResultPreviewAdapter.makeSnapshot(
            from: ready.withStatus(.stale),
            hasCleaningAccess: true,
            noticeMessage: nil,
            noticeTone: .info
        ).status == .stale)
        #expect(UpdateResultPreviewAdapter.makeSnapshot(
            from: ready.withStatus(.unavailable),
            hasCleaningAccess: true,
            noticeMessage: nil,
            noticeTone: .info
        ).status == .unavailable)
        #expect(UpdateResultPreviewAdapter.makeSnapshot(
            from: .empty(),
            hasCleaningAccess: true,
            noticeMessage: nil,
            noticeTone: .info
        ).status == .empty)
    }

    @Test("accepted cleaning locks primary action without paid access")
    func locksAcceptedCleaning() throws {
        let projection = try makeCleaningProjection(verdict: .accepted)

        let snapshot = UpdateResultPreviewAdapter.makeSnapshot(
            from: projection,
            hasCleaningAccess: false,
            noticeMessage: nil,
            noticeTone: .info
        )

        #expect(snapshot.contentAccess == .locked(message: UpgradeCopy.cleaningWrite))
    }

    @Test("rejected cleaning remains reviewable without paid access")
    func ignoresRejectedCleaning() throws {
        let projection = try makeCleaningProjection(verdict: .rejected)

        let snapshot = UpdateResultPreviewAdapter.makeSnapshot(
            from: projection,
            hasCleaningAccess: false,
            noticeMessage: nil,
            noticeTone: .info
        )

        #expect(snapshot.contentAccess == .available)
    }

    @Test("legacy preview preserves all metrics across tracks and albums")
    func mapsLegacyChanges() throws {
        let legacyIDs = try (11 ... 16).map { suffix in
            try #require(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix)))
        }
        let changes = makeLegacyChanges(ids: legacyIDs)

        let snapshot = UpdateResultPreviewAdapter.makeSnapshot(
            changes: changes,
            scopeTitle: "Smart Filter - Missing Genres",
            hasCleaningAccess: true,
            primaryActionLabel: "Enable Writes"
        )

        let metrics = Dictionary(uniqueKeysWithValues: snapshot.metrics.map { ($0.id, $0.value) })
        let resultTracks = snapshot.albums.flatMap(\.tracks)
        let resultChanges = resultTracks.flatMap(\.changes)
        let confidences = Dictionary(uniqueKeysWithValues: resultChanges.map { ($0.id, $0.confidence) })
        #expect(snapshot.mode == .preview)
        #expect(snapshot.scope == "Smart Filter - Missing Genres")
        #expect(snapshot.primaryActionLabel == "Enable Writes")
        #expect(metrics == [
            "changes": "6",
            "accepted": "5",
            "rejected": "1",
            "genre": "1",
            "year": "2",
            "track-cleaning": "1",
            "album-cleaning": "1",
            "artist-rename": "1",
            "affected-tracks": "3",
            "affected-albums": "2",
            "average-confidence": "61%",
        ])
        #expect(Set(resultTracks.map(\.id)) == ["jóga", "bachelorette", "hyperballad"])
        #expect(Set(resultChanges.map(\.id)) == Set(legacyIDs.map(\.uuidString)))
        #expect(confidences[legacyIDs[0].uuidString] == 0.2)
        #expect(confidences[legacyIDs[1].uuidString] == 0)
        #expect(legacyIDs.dropFirst(2).allSatisfy { confidences[$0.uuidString] == 1 })
    }

    @Test("preview-only transition does not require cleaning write access")
    func allowsPreviewOnlyTransition() throws {
        let snapshot = try UpdateResultPreviewAdapter.makeSnapshot(
            from: makeCleaningProjection(verdict: .accepted),
            hasCleaningAccess: false,
            noticeMessage: nil,
            noticeTone: .info
        )

        #expect(UpdateResultActions.canUsePrimary(
            snapshot: snapshot,
            hasAction: true,
            needsAccess: UpdateWorkflowView.needsPrimaryAccess(previewOnly: true)
        ))
        #expect(!UpdateResultActions.canUsePrimary(
            snapshot: snapshot,
            hasAction: true,
            needsAccess: UpdateWorkflowView.needsPrimaryAccess(previewOnly: false)
        ))
    }
}

private func makeLegacyChanges(ids: [UUID]) -> [ProposedChange] {
    let jogaTrack = Track(id: "jóga", name: "Jóga", artist: "Björk", album: "Homogenic")
    let bachelorette = Track(id: "bachelorette", name: "Bachelorette", artist: "Björk", album: "Homogenic")
    let hyperballad = Track(id: "hyperballad", name: "Hyperballad", artist: "Björk", album: "Post")
    return [
        makeLegacyChange(id: ids[0], track: jogaTrack, type: .genreUpdate, confidence: 20),
        makeLegacyChange(id: ids[1], track: jogaTrack, type: .yearUpdate, confidence: -100, isAccepted: false),
        makeLegacyChange(id: ids[2], track: bachelorette, type: .yearRevert, confidence: 110),
        makeLegacyChange(id: ids[3], track: bachelorette, type: .trackCleaning, confidence: 110),
        makeLegacyChange(id: ids[4], track: hyperballad, type: .albumCleaning, confidence: 110),
        makeLegacyChange(id: ids[5], track: hyperballad, type: .artistRename, confidence: 113),
    ]
}

private func makeLegacyChange(
    id: UUID,
    track: Track,
    type: Core.ChangeType,
    confidence: Int,
    isAccepted: Bool = true
) -> ProposedChange {
    ProposedChange(
        id: id,
        track: track,
        changeType: type,
        oldValue: "old",
        newValue: "new",
        confidence: confidence,
        source: "Test",
        isAccepted: isAccepted
    )
}

private let proposalIDs = [
    "00000000-0000-0000-0000-000000000001",
    "00000000-0000-0000-0000-000000000002",
    "00000000-0000-0000-0000-000000000003",
    "00000000-0000-0000-0000-000000000004",
    "00000000-0000-0000-0000-000000000005",
    "00000000-0000-0000-0000-000000000006",
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
        makeItem(index: 5, trackID: "t4", album: "Homogenic", type: .yearUpdate),
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
            itemCount: 6,
            acceptedCount: 5,
            rejectedCount: 1,
            genreCount: 1,
            yearCount: 2,
            trackCleaningCount: 1,
            albumCleaningCount: 1,
            artistRenameCount: 1,
            affectedTrackCount: 4,
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
