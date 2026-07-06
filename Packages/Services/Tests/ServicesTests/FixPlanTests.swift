import Core
import Foundation
import Services
import Testing

@Suite("FixPlan wire format")
struct FixPlanTests {
    @Test("verdict raw values are stable")
    func verdictRawValuesAreStable() {
        #expect(FixPlanItemVerdict.accepted.rawValue == "accepted")
        #expect(FixPlanItemVerdict.rejected.rawValue == "rejected")
    }

    @Test("fix plan items decode from a hard-coded wire fixture")
    func fixPlanItemsDecodeFromWireFixture() throws {
        let json = """
        [{"id":"00000000-0000-0000-0000-000000000001",\
        "identity":{"readID":"12345","appleScriptID":"AS-001","artist":"Test Artist",\
        "album":"Test Album","trackName":"Test Track"},\
        "changeType":"genre_update","oldValue":"Rock","newValue":"Alternative Rock",\
        "confidence":85,"source":"musicbrainz"},\
        {"id":"00000000-0000-0000-0000-000000000002",\
        "identity":{"readID":"67890","appleScriptID":null,"artist":"Second Artist",\
        "album":"Second Album","trackName":"Second Track"},\
        "changeType":"artist_rename","oldValue":"Old Name","newValue":"New Name",\
        "confidence":100,"source":"manual"}]
        """

        let items = try JSONDecoder().decode([FixPlanItem].self, from: Data(json.utf8))

        #expect(items.count == 2)
        #expect(items[0].id == UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        #expect(items[0].identity.readID == "12345")
        #expect(items[0].identity.appleScriptID == "AS-001")
        #expect(items[0].identity.artist == "Test Artist")
        #expect(items[0].identity.album == "Test Album")
        #expect(items[0].identity.trackName == "Test Track")
        #expect(items[0].changeType == .genreUpdate)
        #expect(items[0].oldValue == "Rock")
        #expect(items[0].newValue == "Alternative Rock")
        #expect(items[0].confidence == 85)
        #expect(items[0].source == "musicbrainz")

        #expect(items[1].identity.appleScriptID == nil)
        #expect(items[1].changeType == .artistRename)
    }

    @Test("configuration snapshot decodes from a hard-coded wire fixture")
    func configurationSnapshotDecodesFromWireFixture() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000010","capturedAt":773996400,\
        "updateGenre":true,"updateYear":true,"repairExistingGenreMismatches":false,\
        "forceYearLookup":false,"cleanTrackNames":false,"cleanAlbumNames":false,\
        "minConfidence":60,\
        "fingerprint":"genre=true:year=true:repair=false:forceYear=false:\
        cleanTracks=false:cleanAlbums=false:minConfidence=60"}
        """

        let snapshot = try JSONDecoder().decode(FixPlanConfigurationSnapshot.self, from: Data(json.utf8))

        #expect(snapshot.id == UUID(uuidString: "00000000-0000-0000-0000-000000000010"))
        #expect(snapshot.capturedAt == Date(timeIntervalSinceReferenceDate: 773_996_400))
        #expect(snapshot.updateGenre)
        #expect(snapshot.updateYear)
        #expect(!snapshot.repairExistingGenreMismatches)
        #expect(!snapshot.forceYearLookup)
        #expect(!snapshot.cleanTrackNames)
        #expect(!snapshot.cleanAlbumNames)
        #expect(snapshot.minConfidence == 60)
        #expect(
            snapshot.fingerprint ==
                "genre=true:year=true:repair=false:forceYear=false:cleanTracks=false:cleanAlbums=false:minConfidence=60"
        )
    }

    @Test("item decisions decode from a hard-coded wire fixture")
    func itemDecisionsDecodeFromWireFixture() throws {
        let json = """
        [{"itemID":"00000000-0000-0000-0000-000000000001","verdict":"accepted"},\
        {"itemID":"00000000-0000-0000-0000-000000000002","verdict":"rejected"}]
        """

        let decisions = try JSONDecoder().decode([FixPlanItemDecision].self, from: Data(json.utf8))

        #expect(decisions.count == 2)
        #expect(decisions[0].itemID == UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        #expect(decisions[0].verdict == .accepted)
        #expect(decisions[1].itemID == UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        #expect(decisions[1].verdict == .rejected)
    }

    @Test("fix plan items encode with the exact wire keys")
    func fixPlanItemsEncodeWithExactWireKeys() throws {
        let firstID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let items = [
            FixPlanItem(
                id: firstID,
                identity: FixPlanItemIdentity(
                    readID: "12345",
                    appleScriptID: "AS-001",
                    artist: "Test Artist",
                    album: "Test Album",
                    trackName: "Test Track"
                ),
                changeType: .genreUpdate,
                oldValue: "Rock",
                newValue: "Alternative Rock",
                confidence: 85,
                source: "musicbrainz"
            ),
            FixPlanItem(
                id: secondID,
                identity: FixPlanItemIdentity(
                    readID: "67890",
                    appleScriptID: nil,
                    artist: "Second Artist",
                    album: "Second Album",
                    trackName: "Second Track"
                ),
                changeType: .artistRename,
                oldValue: "Old Name",
                newValue: "New Name",
                confidence: 100,
                source: "manual"
            ),
        ]

        // Encode-side pin: a self-consistent custom Codable would pass the
        // round-trip test below while silently changing what the store writes.
        let data = try JSONEncoder().encode(items)
        let objects = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])

        #expect(objects.count == 2)
        #expect(objects[0]["changeType"] as? String == "genre_update")
        #expect(objects[0]["confidence"] as? Int == 85)
        let firstIdentity = try #require(objects[0]["identity"] as? [String: Any])
        #expect(firstIdentity["readID"] as? String == "12345")
        #expect(firstIdentity["appleScriptID"] as? String == "AS-001")

        #expect(objects[1]["changeType"] as? String == "artist_rename")
        let secondIdentity = try #require(objects[1]["identity"] as? [String: Any])
        #expect(secondIdentity["appleScriptID"] == nil)
    }

    @Test("configuration snapshot fingerprint format is pinned")
    func configurationSnapshotFingerprintFormatIsPinned() {
        let options = UpdateOptions(
            updateGenre: true,
            updateYear: false,
            repairExistingGenreMismatches: true,
            forceYearLookup: false,
            cleanTrackNames: true,
            cleanAlbumNames: false,
            minConfidence: 75,
            autoAccept: true
        )

        let snapshot = FixPlanConfigurationSnapshot.capture(
            options: options,
            capturedAt: Date(timeIntervalSinceReferenceDate: 773_996_400)
        )

        #expect(
            snapshot.fingerprint ==
                "genre=true:year=false:repair=true:forceYear=false:cleanTracks=true:cleanAlbums=false:minConfidence=75"
        )
    }

    @Test("fix plan item round trips through Codable")
    func fixPlanItemRoundTripsThroughCodable() throws {
        let item = FixPlanItem(
            id: UUID(),
            identity: FixPlanItemIdentity(
                readID: "12345",
                appleScriptID: "AS-001",
                artist: "Test Artist",
                album: "Test Album",
                trackName: "Test Track"
            ),
            changeType: .yearUpdate,
            oldValue: "1999",
            newValue: "2000",
            confidence: 90,
            source: "musicbrainz"
        )

        let encoded = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(FixPlanItem.self, from: encoded)

        #expect(decoded == item)
    }

    @Test("configuration snapshot round trips through Codable")
    func configurationSnapshotRoundTripsThroughCodable() throws {
        let snapshot = FixPlanConfigurationSnapshot.capture(
            options: UpdateOptions(),
            capturedAt: Date(timeIntervalSinceReferenceDate: 773_996_400)
        )

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(FixPlanConfigurationSnapshot.self, from: encoded)

        #expect(decoded == snapshot)
    }

    @Test("item decision round trips through Codable")
    func itemDecisionRoundTripsThroughCodable() throws {
        let decision = FixPlanItemDecision(itemID: UUID(), verdict: .rejected)

        let encoded = try JSONEncoder().encode(decision)
        let decoded = try JSONDecoder().decode(FixPlanItemDecision.self, from: encoded)

        #expect(decoded == decision)
    }

    @Test("fix plan revision starts at one, advances, and orders")
    func fixPlanRevisionStartsAtOneAdvancesAndOrders() {
        #expect(FixPlanRevision.initial.value == 1)
        #expect(FixPlanRevision.initial.advanced().value == 2)
        #expect(FixPlanRevision(1) < FixPlanRevision(2))
    }

    @Test("review decision revision starts at one, advances, and orders")
    func reviewDecisionRevisionStartsAtOneAdvancesAndOrders() {
        #expect(ReviewDecisionRevision.initial.value == 1)
        #expect(ReviewDecisionRevision.initial.advanced().value == 2)
        #expect(ReviewDecisionRevision(1) < ReviewDecisionRevision(2))
    }

    // MARK: - FixPlanCapture

    @Test("makePlan maps every ProposedChange field into a FixPlanItem")
    func makePlanMapsEveryProposedChangeFieldIntoFixPlanItem() throws {
        let track = Track(
            id: "MK1",
            name: "Track Name",
            artist: "Track Artist",
            album: "Track Album",
            appleScriptID: "AS-42"
        )
        let proposal = ProposedChange(
            track: track,
            changeType: .genreUpdate,
            oldValue: "Rock",
            newValue: "Alternative Rock",
            confidence: 85,
            source: "musicbrainz"
        )
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 10,
            createdAt: Date(timeIntervalSince1970: 100),
            reason: "unit-test"
        )
        let configuration = FixPlanConfigurationSnapshot.capture(
            options: UpdateOptions(),
            capturedAt: Date(timeIntervalSince1970: 100)
        )

        let plan = try #require(
            FixPlanCapture.makePlan(
                from: [proposal],
                sourceRunID: RunID(),
                scope: scope,
                configuration: configuration,
                createdAt: Date(timeIntervalSince1970: 200)
            )
        )

        #expect(plan.revision == .initial)
        #expect(plan.scope == scope)
        #expect(plan.configuration == configuration)
        #expect(plan.createdAt == Date(timeIntervalSince1970: 200))
        #expect(plan.items.count == 1)

        let item = try #require(plan.items.first)
        #expect(item.id == proposal.id)
        #expect(item.identity.readID == "MK1")
        #expect(item.identity.appleScriptID == "AS-42")
        #expect(item.identity.artist == "Track Artist")
        #expect(item.identity.album == "Track Album")
        #expect(item.identity.trackName == "Track Name")
        #expect(item.changeType == .genreUpdate)
        #expect(item.oldValue == "Rock")
        #expect(item.newValue == "Alternative Rock")
        #expect(item.confidence == 85)
        #expect(item.source == "musicbrainz")
    }

    @Test("makePlan preserves proposal order and item ids")
    func makePlanPreservesProposalOrderAndItemIDs() throws {
        let proposals = (0 ..< 3).map { index in
            ProposedChange(
                track: Track(id: "T\(index)", name: "Track \(index)", artist: "Artist", album: "Album"),
                changeType: .genreUpdate,
                oldValue: "Rock",
                newValue: "Pop",
                confidence: 80,
                source: "manual"
            )
        }

        let plan = try #require(
            FixPlanCapture.makePlan(
                from: proposals,
                sourceRunID: RunID(),
                scope: ProcessingScopeSnapshot.capture(
                    requestedTestArtists: [],
                    knownTrackCount: 3,
                    createdAt: Date(timeIntervalSince1970: 100),
                    reason: "unit-test"
                ),
                configuration: FixPlanConfigurationSnapshot.capture(
                    options: UpdateOptions(),
                    capturedAt: Date(timeIntervalSince1970: 100)
                ),
                createdAt: Date(timeIntervalSince1970: 200)
            )
        )

        #expect(plan.items.map(\.id) == proposals.map(\.id))
        #expect(plan.items.map(\.identity.readID) == ["T0", "T1", "T2"])
    }

    @Test("makePlan passes through a nil appleScriptID")
    func makePlanPassesThroughNilAppleScriptID() throws {
        let track = Track(id: "MK1", name: "Track", artist: "Artist", album: "Album")
        #expect(track.appleScriptID == nil)
        let proposal = ProposedChange(
            track: track,
            changeType: .genreUpdate,
            oldValue: "Rock",
            newValue: "Pop",
            confidence: 80,
            source: "manual"
        )

        let plan = try #require(
            FixPlanCapture.makePlan(
                from: [proposal],
                sourceRunID: RunID(),
                scope: ProcessingScopeSnapshot.capture(
                    requestedTestArtists: [],
                    knownTrackCount: 1,
                    createdAt: Date(timeIntervalSince1970: 100),
                    reason: "unit-test"
                ),
                configuration: FixPlanConfigurationSnapshot.capture(
                    options: UpdateOptions(),
                    capturedAt: Date(timeIntervalSince1970: 100)
                ),
                createdAt: Date(timeIntervalSince1970: 200)
            )
        )

        let item = try #require(plan.items.first)
        #expect(item.identity.appleScriptID == nil)
    }

    @Test("makePlan returns nil for empty proposals")
    func makePlanReturnsNilForEmptyProposals() {
        let plan = FixPlanCapture.makePlan(
            from: [],
            sourceRunID: RunID(),
            scope: ProcessingScopeSnapshot.capture(
                requestedTestArtists: [],
                knownTrackCount: 0,
                createdAt: Date(timeIntervalSince1970: 100),
                reason: "unit-test"
            ),
            configuration: FixPlanConfigurationSnapshot.capture(
                options: UpdateOptions(),
                capturedAt: Date(timeIntervalSince1970: 100)
            ),
            createdAt: Date(timeIntervalSince1970: 200)
        )

        #expect(plan == nil)
    }

    @Test("makePlan output ignores isAccepted — acceptance belongs to the review decision")
    func makePlanOutputIgnoresIsAccepted() throws {
        let sharedTrack = Track(id: "MK1", name: "Track", artist: "Artist", album: "Album")
        let acceptedProposal = ProposedChange(
            track: sharedTrack,
            changeType: .genreUpdate,
            oldValue: "Rock",
            newValue: "Pop",
            confidence: 80,
            source: "manual",
            isAccepted: true
        )
        let rejectedProposal = ProposedChange(
            id: acceptedProposal.id,
            track: sharedTrack,
            changeType: .genreUpdate,
            oldValue: "Rock",
            newValue: "Pop",
            confidence: 80,
            source: "manual",
            isAccepted: false
        )
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: Date(timeIntervalSince1970: 100),
            reason: "unit-test"
        )
        let configuration = FixPlanConfigurationSnapshot.capture(
            options: UpdateOptions(),
            capturedAt: Date(timeIntervalSince1970: 100)
        )

        let acceptedPlan = try #require(
            FixPlanCapture.makePlan(
                from: [acceptedProposal],
                sourceRunID: RunID(),
                scope: scope,
                configuration: configuration,
                createdAt: Date(timeIntervalSince1970: 200)
            )
        )
        let rejectedPlan = try #require(
            FixPlanCapture.makePlan(
                from: [rejectedProposal],
                sourceRunID: RunID(),
                scope: scope,
                configuration: configuration,
                createdAt: Date(timeIntervalSince1970: 200)
            )
        )

        #expect(acceptedPlan.items == rejectedPlan.items)
    }
}
