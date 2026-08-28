import Core
import Foundation
import Testing
@testable import Services

@Suite("FixPlanProjection")
struct FixPlanProjectionTests {
    @Test("ready projection exposes plan identity, decision revision, counts, and items")
    func mapsReadyProjection() {
        let plan = makePlan(items: [
            makeItem(id: itemID(1), type: .genreUpdate, confidence: 80),
            makeItem(id: itemID(2), type: .yearUpdate, confidence: 100),
        ])
        let decision = FixPlanReviewer.initialDecision(for: plan, at: decidedAt)
        let staleness = FixPlanStaleness.evaluate(
            plan: plan,
            currentScope: plan.scope,
            currentConfiguration: plan.configuration
        )

        let projection = FixPlanProjector.makeProjection(
            plan: plan,
            decision: decision,
            staleness: staleness
        )

        #expect(projection.status == .ready)
        #expect(projection.planID == plan.id)
        #expect(projection.planRevision == plan.revision)
        #expect(projection.decisionRevision == decision.revision)
        #expect(projection.sourceRunID == plan.sourceRunID)
        #expect(projection.itemCount == 2)
        #expect(projection.acceptedCount == 2)
        #expect(projection.rejectedCount == 0)
        #expect(projection.genreCount == 1)
        #expect(projection.yearCount == 1)
        #expect(projection.averageConfidence == 90)
        #expect(projection.canApply)
        #expect(projection.items.map(\.verdict) == [.accepted, .accepted])
    }

    @Test("summary covers every change type and distinct affected identity")
    func mapsCompleteSummary() {
        let plan = makePlan(items: [
            makeItem(id: itemID(1), readID: "t1", artist: "Björk", album: "Post", type: .genreUpdate),
            makeItem(id: itemID(2), readID: "t1", artist: "Björk", album: "Post", type: .yearRevert),
            makeItem(id: itemID(3), readID: "t2", artist: "Björk", album: "Post", type: .trackCleaning),
            makeItem(id: itemID(4), readID: "t3", artist: "Björk", album: "Homogenic", type: .albumCleaning),
            makeItem(id: itemID(5), readID: "t3", artist: "Björk", album: "Homogenic", type: .artistRename),
        ])
        let decision = FixPlanReviewer.initialDecision(for: plan, at: decidedAt)
        let projection = FixPlanProjector.makeProjection(
            plan: plan,
            decision: decision,
            staleness: FixPlanStaleness.evaluate(
                plan: plan,
                currentScope: plan.scope,
                currentConfiguration: plan.configuration
            )
        )

        #expect(projection.genreCount == 1)
        #expect(projection.yearCount == 1)
        #expect(projection.trackCleaningCount == 1)
        #expect(projection.albumCleaningCount == 1)
        #expect(projection.artistRenameCount == 1)
        #expect(projection.affectedTrackCount == 3)
        #expect(projection.affectedAlbumCount == 2)
        #expect(projection.scope == plan.scope)
    }

    @Test("average confidence stays a percentage when scores exceed 100")
    func averageConfidenceIsClampedForDisplay() {
        // Domain scores are unclamped for Python parity — a perfect match is
        // 125 — but every consumer renders this value as "N%".
        let plan = makePlan(items: [
            makeItem(id: itemID(1), type: .genreUpdate, confidence: 125),
            makeItem(id: itemID(2), type: .yearUpdate, confidence: 125),
        ])
        let decision = FixPlanReviewer.initialDecision(for: plan, at: decidedAt)
        let staleness = FixPlanStaleness.evaluate(
            plan: plan,
            currentScope: plan.scope,
            currentConfiguration: plan.configuration
        )

        let projection = FixPlanProjector.makeProjection(
            plan: plan,
            decision: decision,
            staleness: staleness
        )

        #expect(projection.averageConfidence == 100)
    }

    @Test("projection counts rejected decisions without mutating the plan")
    func countsRejectedDecisions() {
        let rejectedID = itemID(1)
        let plan = makePlan(items: [
            makeItem(id: rejectedID, type: .genreUpdate),
            makeItem(id: itemID(2), type: .yearUpdate),
        ])
        let initialDecision = FixPlanReviewer.initialDecision(for: plan, at: decidedAt)
        guard let decision = FixPlanReviewer.togglingItem(
            rejectedID,
            in: initialDecision,
            at: Date(timeIntervalSince1970: 102)
        ) else {
            Issue.record("Expected toggling an existing fix-plan item to produce a decision")
            return
        }

        let projection = FixPlanProjector.makeProjection(
            plan: plan,
            decision: decision,
            staleness: FixPlanStaleness.evaluate(
                plan: plan,
                currentScope: plan.scope,
                currentConfiguration: plan.configuration
            )
        )

        #expect(projection.acceptedCount == 1)
        #expect(projection.rejectedCount == 1)
        #expect(projection.items.first?.verdict == .rejected)
        #expect(plan.items.count == 2)
    }

    @Test("stale projection keeps items but disables apply")
    func staleProjectionKeepsItemsButDisablesApply() {
        let plan = makePlan(items: [makeItem(type: .genreUpdate)])
        let decision = FixPlanReviewer.initialDecision(for: plan, at: decidedAt)
        let staleConfiguration = makeConfiguration(minConfidence: 95)

        let projection = FixPlanProjector.makeProjection(
            plan: plan,
            decision: decision,
            staleness: FixPlanStaleness.evaluate(
                plan: plan,
                currentScope: plan.scope,
                currentConfiguration: staleConfiguration
            )
        )

        #expect(projection.status == .stale)
        #expect(!projection.canApply)
        #expect(projection.stalenessReasons == [.configurationChanged])
        #expect(projection.items.count == 1)
    }

    @Test("accepted item without write identity disables apply")
    func missingWriteIDDisablesApply() {
        let plan = makePlan(items: [
            makeItem(type: .genreUpdate, writeID: nil),
        ])
        let decision = FixPlanReviewer.initialDecision(for: plan, at: decidedAt)

        let projection = FixPlanProjector.makeProjection(
            plan: plan,
            decision: decision,
            staleness: FixPlanStaleness.evaluate(
                plan: plan,
                currentScope: plan.scope,
                currentConfiguration: plan.configuration
            )
        )

        #expect(!projection.canApply)
        #expect(projection.operationalIssues.map(\.category) == [.safetyBlocked])
    }

    @Test("legacy plan without certified admission is safety blocked")
    func blocksLegacyPlan() {
        let plan = makePlan(
            items: [makeItem(type: .genreUpdate)],
            admission: .legacyUncertified
        )
        let decision = FixPlanReviewer.initialDecision(for: plan, at: decidedAt)

        let projection = FixPlanProjector.makeProjection(
            plan: plan,
            decision: decision,
            staleness: FixPlanStaleness.evaluate(
                plan: plan,
                currentScope: plan.scope,
                currentConfiguration: plan.configuration
            )
        )

        #expect(!projection.canApply)
        #expect(projection.operationalIssues.contains { issue in
            issue.id == "fix-plan-admission" && issue.category == .safetyBlocked
        })
    }

    @Test("restored plan with mismatched certified admission is safety blocked")
    func blocksMismatchedAdmission() {
        let admittedScope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: ["Another Artist"],
            knownTrackCount: 42,
            createdAt: Date(timeIntervalSince1970: 100),
            reason: "projection-test"
        )
        let plan = makePlan(
            items: [makeItem(type: .genreUpdate)],
            admission: .certified(certifiedAdmission(scope: admittedScope))
        )
        let decision = FixPlanReviewer.initialDecision(for: plan, at: decidedAt)

        let projection = FixPlanProjector.makeProjection(
            plan: plan,
            decision: decision,
            staleness: FixPlanStaleness.evaluate(
                plan: plan,
                currentScope: plan.scope,
                currentConfiguration: plan.configuration
            )
        )

        #expect(!projection.canApply)
        #expect(projection.operationalIssues.contains { issue in
            issue.id == "fix-plan-admission" && issue.category == .safetyBlocked
        })
    }

    @Test("rejected item without write identity does not block accepted items")
    func rejectedMissingIDAllowsApply() {
        let missingID = itemID(1)
        let plan = makePlan(items: [
            makeItem(id: missingID, type: .genreUpdate, writeID: nil),
            makeItem(id: itemID(2), type: .yearUpdate),
        ])
        let initialDecision = FixPlanReviewer.initialDecision(for: plan, at: decidedAt)
        let decision = FixPlanReviewer.togglingItem(
            missingID,
            in: initialDecision,
            at: Date(timeIntervalSince1970: 102)
        )
        guard let decision else {
            Issue.record("Expected toggling an existing fix-plan item to produce a decision")
            return
        }

        let projection = FixPlanProjector.makeProjection(
            plan: plan,
            decision: decision,
            staleness: FixPlanStaleness.evaluate(
                plan: plan,
                currentScope: plan.scope,
                currentConfiguration: plan.configuration
            )
        )

        #expect(projection.canApply)
        #expect(projection.operationalIssues.isEmpty)
    }

    @Test("mixed accepted plan blocks empty write identity")
    func mixedMissingIDBlocksApply() {
        let plan = makePlan(items: [
            makeItem(id: itemID(1), type: .genreUpdate),
            makeItem(id: itemID(2), type: .yearUpdate, writeID: "  "),
        ])
        let decision = FixPlanReviewer.initialDecision(for: plan, at: decidedAt)

        let projection = FixPlanProjector.makeProjection(
            plan: plan,
            decision: decision,
            staleness: FixPlanStaleness.evaluate(
                plan: plan,
                currentScope: plan.scope,
                currentConfiguration: plan.configuration
            )
        )

        #expect(!projection.canApply)
        #expect(projection.operationalIssues.count == 1)
        #expect(projection.operationalIssues.first?.technicalDetail == "Accepted items without AppleScript ID: 1")
        #expect(projection.items.map(\.hasWriteID) == [true, false])
    }

    @Test("artist preview discloses its coupled album artist effect")
    func coupledArtistEffectIsVisible() {
        let plan = makePlan(items: [
            makeItem(
                type: .artistRename,
                albumArtistChange: AlbumArtistChange(oldValue: "AFX", newValue: "Aphex Twin")
            ),
        ])
        let decision = FixPlanReviewer.initialDecision(for: plan, at: decidedAt)

        let projection = FixPlanProjector.makeProjection(
            plan: plan,
            decision: decision,
            staleness: FixPlanStaleness.evaluate(
                plan: plan,
                currentScope: plan.scope,
                currentConfiguration: plan.configuration
            )
        )

        #expect(projection.items[0].oldValue == "2013 (album artist: AFX)")
        #expect(projection.items[0].newValue == "2014 (album artist: Aphex Twin)")
    }
}

private let decidedAt = Date(timeIntervalSince1970: 101)

private func makePlan(
    items: [FixPlanItem],
    configuration: FixPlanConfig = makeConfiguration(),
    admission: FixPlanAdmission? = nil
) -> FixPlan {
    let scope = ProcessingScopeSnapshot.capture(
        requestedTestArtists: ["Aphex Twin"],
        knownTrackCount: 42,
        createdAt: Date(timeIntervalSince1970: 100),
        reason: "projection-test"
    )
    return FixPlan(restoring: .init(
        id: FixPlanID(rawValue: itemID(99)),
        revision: .initial,
        sourceRunID: RunID(rawValue: itemID(98)),
        createdAt: Date(timeIntervalSince1970: 100),
        configuration: configuration,
        scope: scope,
        admission: admission ?? .certified(certifiedAdmission(scope: scope)),
        items: items
    ))
}

private func certifiedAdmission(scope: ProcessingScopeSnapshot) -> ProcessingAdmission {
    guard let membership = try? MembershipFingerprint.make(ids: []) else {
        preconditionFailure("Empty membership must have a canonical fingerprint")
    }
    return ProcessingAdmission(
        scopeID: scope.id,
        certificate: ScopeCertificate(
            id: UUID(),
            revision: .initial,
            membership: membership,
            testArtists: scope.normalizedTestArtists,
            fieldSet: .processingV1,
            evidence: ScopeEvidence(
                requestedFingerprint: membership.fingerprint,
                observedFingerprint: membership.fingerprint,
                trackCount: scope.knownTrackCount ?? 0
            ),
            observedAt: scope.createdAt
        ),
        maximumMetadataAge: nil
    )
}

private func makeConfiguration(minConfidence: Int = 80) -> FixPlanConfig {
    FixPlanConfig.capture(
        configuration: AppConfiguration(),
        options: UpdateOptions(
            updateGenre: true,
            updateYear: true,
            repairExistingGenreMismatches: false,
            forceYearLookup: false,
            cleanTrackNames: false,
            cleanAlbumNames: false,
            minConfidence: minConfidence,
            autoAccept: false
        ),
        capturedAt: Date(timeIntervalSince1970: 90)
    )
}

private func makeItem(
    id: UUID = itemID(1),
    readID: String? = nil,
    artist: String = "Aphex Twin",
    album: String = "Syro",
    type: ChangeType,
    confidence: Int = 90,
    writeID: String? = "script-id",
    albumArtistChange: AlbumArtistChange? = nil
) -> FixPlanItem {
    FixPlanItem(
        id: id,
        identity: FixPlanItemIdentity(
            readID: readID ?? "read-\(id.uuidString)",
            appleScriptID: writeID,
            artist: artist,
            album: album,
            trackName: "minipops 67"
        ),
        changeType: type,
        oldValue: type == .genreUpdate ? "Electronic" : "2013",
        newValue: type == .genreUpdate ? "IDM" : "2014",
        confidence: confidence,
        source: "musicbrainz",
        albumArtistChange: albumArtistChange
    )
}

private func itemID(_ value: Int) -> UUID {
    guard let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value)) else {
        preconditionFailure("Failed to build a deterministic test UUID")
    }
    return id
}
