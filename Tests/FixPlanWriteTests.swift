import Core
import Foundation
import Testing
@testable import Genre_Updater
@testable import Services

@Suite("FixPlanWrite")
struct FixPlanWriteTests {
    @Test("Legacy plans cannot create write input")
    func legacyPlanCannotCreateWriteInput() {
        let item = fixPlanItem(id: UUID(), index: 1)
        let plan = fixPlan(items: [item], isLegacy: true)
        let decision = reviewDecision(
            for: plan,
            items: [FixPlanItemDecision(itemID: item.id, verdict: .accepted)]
        )

        #expect(throws: FixPlanWrite.Failure.self) {
            _ = try FixPlanWrite.makeInput(
                plan: plan,
                decision: decision,
                configuration: writeConfiguration(for: plan, decidedAt: decision.decidedAt)
            )
        }
    }

    @Test("Restored plan with mismatched certified scope cannot create write input")
    func mismatchedCertifiedPlanCannotCreateWriteInput() {
        let item = fixPlanItem(id: UUID(), index: 1)
        let capturedAt = Date(timeIntervalSince1970: 100)
        let planScope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: ["Plan Artist"],
            knownTrackCount: 1,
            createdAt: capturedAt,
            reason: "unit-test"
        )
        let admittedScope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: ["Admitted Artist"],
            knownTrackCount: 1,
            createdAt: capturedAt,
            reason: "unit-test"
        )
        let admitted = workflowProcessingAdmission(scope: admittedScope)
        let forgedAdmission = ProcessingAdmission(
            scopeID: planScope.id,
            certificate: admitted.certificate,
            maximumMetadataAge: admitted.maximumMetadataAge
        )
        let plan = FixPlan(restoring: .init(
            id: FixPlanID(),
            revision: .initial,
            sourceRunID: RunID(),
            createdAt: capturedAt,
            configuration: FixPlanConfig.capture(
                configuration: AppConfiguration(),
                options: UpdateOptions(),
                capturedAt: capturedAt
            ),
            scope: planScope,
            admission: .certified(forgedAdmission),
            items: [item]
        ))
        let decision = reviewDecision(
            for: plan,
            items: [FixPlanItemDecision(itemID: item.id, verdict: .accepted)]
        )

        #expect(throws: FixPlanWrite.Failure.self) {
            _ = try FixPlanWrite.makeInput(
                plan: plan,
                decision: decision,
                configuration: writeConfiguration(for: plan, decidedAt: decision.decidedAt)
            )
        }
    }

    @Test("Certified plans preserve their exact admission in write input")
    func certifiedPlanPreservesAdmission() throws {
        let item = fixPlanItem(id: UUID(), index: 1)
        let plan = try certifiedFixPlan(items: [item])
        let decision = reviewDecision(
            for: plan,
            items: [FixPlanItemDecision(itemID: item.id, verdict: .accepted)]
        )

        let input = try FixPlanWrite.makeInput(
            plan: plan,
            decision: decision,
            configuration: writeConfiguration(for: plan, decidedAt: decision.decidedAt)
        )

        guard case let .certified(admission) = plan.admission else {
            Issue.record("Expected certified plan")
            return
        }
        #expect(input.admission == admission)
    }

    @Test("reviewed write ID refresh uses typed database identities")
    func usesPlanSettings() async throws {
        let scriptClient = WriteIDScriptSpy()
        let mapper = TrackIDMapper()
        let changes = (1 ... 3).map { index in
            ProposedChange(
                track: musicKitTrack(index: index),
                changeType: .genreUpdate,
                oldValue: "Rock",
                newValue: "Metal",
                confidence: 90,
                source: "review-test"
            )
        }
        await scriptClient.setTracks(changes.map { appleScriptTrack(from: $0.track) })

        try await FixPlanWrite.prepareWriteIDs(
            for: changes,
            mapper: mapper,
            verifier: scriptClient
        )

        let calls = await scriptClient.fetchCalls
        let firstID = try #require(MusicDatabaseTrackID(rawValue: "AS-1"))
        let secondID = try #require(MusicDatabaseTrackID(rawValue: "AS-2"))
        let thirdID = try #require(MusicDatabaseTrackID(rawValue: "AS-3"))
        #expect(Set(calls.flatMap(\.self)) == [
            firstID,
            secondID,
            thirdID,
        ])
        for index in 1 ... 3 {
            #expect(await mapper.appleScriptID(forMusicKitID: "MK-\(index)") == "AS-\(index)")
        }
    }

    @Test("reviewed write rejects a reused database ID")
    func rejectsReusedDatabaseID() async throws {
        let verifier = WriteIDScriptSpy()
        let mapper = TrackIDMapper()
        let change = ProposedChange(
            track: musicKitTrack(index: 1),
            changeType: .genreUpdate,
            oldValue: "Rock",
            newValue: "Metal",
            confidence: 90,
            source: "review-test"
        )
        await verifier.setTracks([
            Track(
                id: "AS-1",
                name: "Replacement Track",
                artist: "Different Artist",
                album: "Different Album",
                appleScriptID: "AS-1"
            ),
        ])

        await #expect(throws: FixPlanWrite.Failure.self) {
            try await FixPlanWrite.prepareWriteIDs(
                for: [change],
                mapper: mapper,
                verifier: verifier
            )
        }
        #expect(await mapper.appleScriptID(forMusicKitID: "MK-1") == nil)
    }

    @Test("reviewed write rejects a reused database ID with another album artist")
    func rejectsReusedDatabaseIDByAlbumArtist() async throws {
        let verifier = WriteIDScriptSpy()
        let mapper = TrackIDMapper()
        let change = ProposedChange(
            track: musicKitTrack(index: 1, albumArtist: "Artist"),
            changeType: .genreUpdate,
            oldValue: "Rock",
            newValue: "Metal",
            confidence: 90,
            source: "review-test"
        )
        await verifier.setTracks([
            Track(
                id: "AS-1",
                name: change.track.name,
                artist: change.track.artist,
                album: change.track.album,
                albumArtist: "Compilation Artist",
                appleScriptID: "AS-1"
            ),
        ])

        await #expect(throws: FixPlanWrite.Failure.self) {
            try await FixPlanWrite.prepareWriteIDs(
                for: [change],
                mapper: mapper,
                verifier: verifier
            )
        }
        #expect(await mapper.appleScriptID(forMusicKitID: "MK-1") == nil)
    }

    @Test("reviewed write maps decision verdicts")
    func mapsDecisionVerdicts() throws {
        let firstItem = fixPlanItem(id: UUID(), index: 1)
        let secondItem = fixPlanItem(id: UUID(), index: 2)
        let plan = fixPlan(items: [firstItem, secondItem])
        let decision = reviewDecision(
            for: plan,
            items: [
                FixPlanItemDecision(itemID: firstItem.id, verdict: .accepted),
                FixPlanItemDecision(itemID: secondItem.id, verdict: .rejected)
            ]
        )

        let changes = try FixPlanWrite.proposedChanges(from: plan, decision: decision)

        #expect(changes.map(\.id) == [firstItem.id, secondItem.id])
        #expect(changes.map(\.isAccepted) == [true, false])
    }

    @Test("Reviewed write restores coupled album artist evidence from the plan")
    func restoresAlbumArtistEvidence() throws {
        let item = FixPlanItem(
            id: UUID(),
            identity: FixPlanItemIdentity(
                readID: "MK-1",
                appleScriptID: "AS-1",
                artist: "Massive Attack",
                album: "Mezzanine",
                trackName: "Teardrop",
                albumArtist: "Massive Attack"
            ),
            changeType: .artistRename,
            oldValue: "Massive",
            newValue: "Massive Attack",
            confidence: 100,
            source: "Artist Renamer",
            albumArtistChange: AlbumArtistChange(
                oldValue: "Massive",
                newValue: "Massive Attack"
            )
        )
        let plan = fixPlan(items: [item])
        let decision = reviewDecision(
            for: plan,
            items: [FixPlanItemDecision(itemID: item.id, verdict: .accepted)]
        )

        let change = try #require(FixPlanWrite.proposedChanges(from: plan, decision: decision).first)

        #expect(change.track.albumArtist == "Massive Attack")
        #expect(change.albumArtistChange == item.albumArtistChange)
    }

    @Test("reviewed write rejects duplicate decision items")
    func rejectsDuplicateItems() {
        let firstItem = fixPlanItem(id: UUID(), index: 1)
        let secondItem = fixPlanItem(id: UUID(), index: 2)
        let plan = fixPlan(items: [firstItem, secondItem])
        let decision = reviewDecision(
            for: plan,
            items: [
                FixPlanItemDecision(itemID: firstItem.id, verdict: .accepted),
                FixPlanItemDecision(itemID: firstItem.id, verdict: .rejected)
            ]
        )

        expectInvalidDecision(plan: plan, decision: decision)
    }

    @Test("reviewed write rejects unknown decision items")
    func rejectsUnknownItems() {
        let firstItem = fixPlanItem(id: UUID(), index: 1)
        let secondItem = fixPlanItem(id: UUID(), index: 2)
        let plan = fixPlan(items: [firstItem, secondItem])
        let decision = reviewDecision(
            for: plan,
            items: [
                FixPlanItemDecision(itemID: firstItem.id, verdict: .accepted),
                FixPlanItemDecision(itemID: UUID(), verdict: .rejected)
            ]
        )

        expectInvalidDecision(plan: plan, decision: decision)
    }

    @Test("reviewed write rejects missing decision items")
    func rejectsMissingItems() {
        let firstItem = fixPlanItem(id: UUID(), index: 1)
        let secondItem = fixPlanItem(id: UUID(), index: 2)
        let plan = fixPlan(items: [firstItem, secondItem])
        let decision = reviewDecision(
            for: plan,
            items: [
                FixPlanItemDecision(itemID: firstItem.id, verdict: .accepted)
            ]
        )

        expectInvalidDecision(plan: plan, decision: decision)
    }

    @Test("accepted cleaning makes the reviewed write paid")
    func derivesPaidFeatureFromAcceptedWork() {
        let workItems = [
            RunWorkItem(item: fixPlanItem(id: UUID(), index: 1)),
            RunWorkItem(item: fixPlanItem(id: UUID(), index: 2, changeType: .trackCleaning)),
        ]

        #expect(FixPlanWrite.requiredFeature(for: workItems) == .artistAlbumCleaning)
    }

    @Test("genre and year work keep the reviewed write on free admission")
    func keepsMetadataWriteFree() {
        let workItems = [
            RunWorkItem(item: fixPlanItem(id: UUID(), index: 1, changeType: .genreUpdate)),
            RunWorkItem(item: fixPlanItem(id: UUID(), index: 2, changeType: .yearUpdate)),
            RunWorkItem(item: fixPlanItem(id: UUID(), index: 3, changeType: .yearRevert)),
        ]

        #expect(FixPlanWrite.requiredFeature(for: workItems) == nil)
    }
}

private actor WriteIDScriptSpy: MusicAppVerifying {
    private var tracksByID: [String: Track] = [:]
    private(set) var fetchCalls: [[MusicDatabaseTrackID]] = []

    func setTracks(_ tracks: [Track]) {
        tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
    }

    func fetchMetadata(for databaseIDs: [MusicDatabaseTrackID]) async throws -> [Track] {
        fetchCalls.append(databaseIDs)
        return databaseIDs.compactMap { tracksByID[$0.rawValue] }
    }
}

private func musicKitTrack(index: Int, albumArtist: String? = nil) -> Track {
    Track(
        id: "MK-\(index)",
        name: "Track \(index)",
        artist: "Artist",
        album: "Album",
        albumArtist: albumArtist,
        appleScriptID: "AS-\(index)"
    )
}

private func appleScriptTrack(from track: Track) -> Track {
    Track(
        id: track.appleScriptID ?? track.id,
        name: track.name,
        artist: track.artist,
        album: track.album,
        albumArtist: track.albumArtist,
        appleScriptID: track.appleScriptID
    )
}

private func fixPlan(items: [FixPlanItem], isLegacy: Bool = false) -> FixPlan {
    let capturedAt = Date(timeIntervalSince1970: 100)
    let scope = ProcessingScopeSnapshot.capture(
        requestedTestArtists: [],
        knownTrackCount: items.count,
        createdAt: capturedAt,
        reason: "unit-test"
    )
    return FixPlan(restoring: .init(
        id: FixPlanID(),
        revision: .initial,
        sourceRunID: RunID(),
        createdAt: capturedAt,
        configuration: FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(),
            capturedAt: capturedAt
        ),
        scope: scope,
        admission: isLegacy
            ? .legacyUncertified
            : .certified(workflowProcessingAdmission(scope: scope)),
        items: items
    ))
}

private func certifiedFixPlan(items: [FixPlanItem]) throws -> FixPlan {
    let capturedAt = Date(timeIntervalSince1970: 100)
    let scope = ProcessingScopeSnapshot.capture(
        requestedTestArtists: [],
        knownTrackCount: items.count,
        createdAt: capturedAt,
        reason: "unit-test"
    )
    let databaseIDs = try items.map { item in
        try #require(MusicDatabaseTrackID(rawValue: item.identity.appleScriptID ?? item.identity.readID))
    }
    let membership = try MembershipFingerprint.make(ids: databaseIDs)
    let admission = ProcessingAdmission(
        scopeID: scope.id,
        certificate: ScopeCertificate(
            id: UUID(),
            revision: .initial,
            membership: membership,
            testArtists: [],
            fieldSet: .processingV1,
            evidence: ScopeEvidence(
                requestedFingerprint: membership.fingerprint,
                observedFingerprint: membership.fingerprint,
                trackCount: databaseIDs.count
            ),
            observedAt: capturedAt
        ),
        maximumMetadataAge: nil
    )
    return try FixPlan(
        id: FixPlanID(),
        revision: .initial,
        sourceRunID: RunID(),
        createdAt: capturedAt,
        configuration: FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(),
            capturedAt: capturedAt
        ),
        scope: scope,
        admission: admission,
        items: items
    )
}

private func writeConfiguration(for plan: FixPlan, decidedAt: Date) -> RunConfig {
    RunConfig(
        capturedAt: decidedAt,
        writeAuthority: .reviewedPlan,
        automation: .manualOnly,
        scopeID: plan.scope.id,
        settings: plan.configuration,
        hadRecoveryHold: false
    )
}

private func reviewDecision(
    for plan: FixPlan,
    items: [FixPlanItemDecision]
) -> FixPlanReviewDecision {
    FixPlanReviewDecision(
        planID: plan.id,
        planRevision: plan.revision,
        revision: .initial,
        decidedAt: Date(timeIntervalSince1970: 110),
        itemDecisions: items
    )
}

private func expectInvalidDecision(
    plan: FixPlan,
    decision: FixPlanReviewDecision
) {
    do {
        _ = try FixPlanWrite.proposedChanges(from: plan, decision: decision)
        Issue.record("Expected invalid decision items")
    } catch let error as FixPlanWrite.Failure {
        guard case .invalidDecisionItems = error else {
            Issue.record("Expected invalidDecisionItems, got \(error)")
            return
        }
    } catch {
        Issue.record("Expected FixPlanWrite.Failure, got \(error)")
    }
}

private func fixPlanItem(
    id: UUID,
    index: Int,
    changeType: ChangeType = .genreUpdate
) -> FixPlanItem {
    FixPlanItem(
        id: id,
        identity: FixPlanItemIdentity(
            readID: "MK-\(index)",
            appleScriptID: "AS-\(index)",
            artist: "Artist",
            album: "Album",
            trackName: "Track \(index)"
        ),
        changeType: changeType,
        oldValue: "Rock",
        newValue: "Metal",
        confidence: 90,
        source: "review-test"
    )
}
