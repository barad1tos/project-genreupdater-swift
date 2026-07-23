import Core
import Foundation
import Services
import Testing

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
}

private let decidedAt = Date(timeIntervalSince1970: 101)

private func makePlan(
    items: [FixPlanItem],
    configuration: FixPlanConfig = makeConfiguration()
) -> FixPlan {
    FixPlan(
        id: FixPlanID(rawValue: itemID(99)),
        revision: .initial,
        sourceRunID: RunID(rawValue: itemID(98)),
        createdAt: Date(timeIntervalSince1970: 100),
        configuration: configuration,
        scope: ProcessingScopeSnapshot.capture(
            requestedTestArtists: ["Aphex Twin"],
            knownTrackCount: 42,
            createdAt: Date(timeIntervalSince1970: 100),
            reason: "projection-test"
        ),
        items: items
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
    type: ChangeType,
    confidence: Int = 90,
    writeID: String? = "script-id"
) -> FixPlanItem {
    FixPlanItem(
        id: id,
        identity: FixPlanItemIdentity(
            readID: "read-\(id.uuidString)",
            appleScriptID: writeID,
            artist: "Aphex Twin",
            album: "Syro",
            trackName: "minipops 67"
        ),
        changeType: type,
        oldValue: type == .genreUpdate ? "Electronic" : "2013",
        newValue: type == .genreUpdate ? "IDM" : "2014",
        confidence: confidence,
        source: "musicbrainz"
    )
}

private func itemID(_ value: Int) -> UUID {
    guard let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value)) else {
        preconditionFailure("Failed to build a deterministic test UUID")
    }
    return id
}
