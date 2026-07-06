import Foundation
import Services
import Testing

// MARK: - Helpers

private func makeReviewerTestItem(id: UUID = UUID()) -> FixPlanItem {
    FixPlanItem(
        id: id,
        identity: FixPlanItemIdentity(
            readID: "T1",
            appleScriptID: "AS-1",
            artist: "Artist",
            album: "Album",
            trackName: "Track"
        ),
        changeType: .genreUpdate,
        oldValue: "Rock",
        newValue: "Electronic",
        confidence: 90,
        source: "musicbrainz"
    )
}

private func makeReviewerTestPlan(items: [FixPlanItem]) -> FixPlan {
    let capturedAt = Date(timeIntervalSince1970: 100)
    return FixPlan(
        id: FixPlanID(),
        revision: .initial,
        sourceRunID: RunID(),
        createdAt: capturedAt,
        configuration: FixPlanConfigurationSnapshot.capture(options: UpdateOptions(), capturedAt: capturedAt),
        scope: ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 10,
            createdAt: capturedAt,
            reason: "unit-test"
        ),
        items: items
    )
}

// MARK: - Tests

@Suite("FixPlanReviewer — pure review transforms")
struct FixPlanReviewerTests {
    @Test("initial decision accepts every item at revision one")
    func initialDecisionAcceptsEveryItemAtRevisionOne() {
        let items = [makeReviewerTestItem(), makeReviewerTestItem(), makeReviewerTestItem()]
        let plan = makeReviewerTestPlan(items: items)

        let decision = FixPlanReviewer.initialDecision(for: plan, at: Date(timeIntervalSince1970: 200))

        #expect(decision.planID == plan.id)
        #expect(decision.planRevision == plan.revision)
        #expect(decision.revision == .initial)
        #expect(decision.itemDecisions.count == 3)
        #expect(decision.itemDecisions.allSatisfy { $0.verdict == .accepted })
        #expect(decision.itemDecisions.map(\.itemID) == items.map(\.id))
    }

    @Test("acceptingAll advances revision by one and accepts every item")
    func acceptingAllAdvancesRevisionAndAcceptsEveryItem() {
        let plan = makeReviewerTestPlan(items: [makeReviewerTestItem(), makeReviewerTestItem()])
        let initial = FixPlanReviewer.initialDecision(for: plan, at: Date(timeIntervalSince1970: 200))
        let rejected = FixPlanReviewer.rejectingAll(initial, at: Date(timeIntervalSince1970: 201))

        let accepted = FixPlanReviewer.acceptingAll(rejected, at: Date(timeIntervalSince1970: 202))

        #expect(accepted.revision == rejected.revision.advanced())
        #expect(accepted.planID == plan.id)
        #expect(accepted.planRevision == plan.revision)
        #expect(accepted.itemDecisions.allSatisfy { $0.verdict == .accepted })
    }

    @Test("rejectingAll advances revision by one and rejects every item")
    func rejectingAllAdvancesRevisionAndRejectsEveryItem() {
        let plan = makeReviewerTestPlan(items: [makeReviewerTestItem(), makeReviewerTestItem()])
        let initial = FixPlanReviewer.initialDecision(for: plan, at: Date(timeIntervalSince1970: 200))

        let rejected = FixPlanReviewer.rejectingAll(initial, at: Date(timeIntervalSince1970: 201))

        #expect(rejected.revision == initial.revision.advanced())
        #expect(rejected.planID == plan.id)
        #expect(rejected.planRevision == plan.revision)
        #expect(rejected.itemDecisions.allSatisfy { $0.verdict == .rejected })
    }

    @Test("togglingItem flips exactly one verdict and advances revision by one")
    func togglingItemFlipsExactlyOneVerdictAndAdvancesRevision() throws {
        let firstItem = makeReviewerTestItem()
        let secondItem = makeReviewerTestItem()
        let plan = makeReviewerTestPlan(items: [firstItem, secondItem])
        let initial = FixPlanReviewer.initialDecision(for: plan, at: Date(timeIntervalSince1970: 200))

        let toggled = try #require(
            FixPlanReviewer.togglingItem(firstItem.id, in: initial, at: Date(timeIntervalSince1970: 201))
        )

        #expect(toggled.revision == initial.revision.advanced())
        #expect(toggled.planID == plan.id)
        #expect(toggled.planRevision == plan.revision)
        let firstDecision = try #require(toggled.itemDecisions.first { $0.itemID == firstItem.id })
        let secondDecision = try #require(toggled.itemDecisions.first { $0.itemID == secondItem.id })
        #expect(firstDecision.verdict == .rejected)
        #expect(secondDecision.verdict == .accepted)
    }

    @Test("togglingItem returns nil for an itemID not part of the decision")
    func togglingItemReturnsNilForUnknownItemID() {
        let plan = makeReviewerTestPlan(items: [makeReviewerTestItem()])
        let initial = FixPlanReviewer.initialDecision(for: plan, at: Date(timeIntervalSince1970: 200))

        let toggled = FixPlanReviewer.togglingItem(UUID(), in: initial, at: Date(timeIntervalSince1970: 201))

        #expect(toggled == nil)
    }
}
