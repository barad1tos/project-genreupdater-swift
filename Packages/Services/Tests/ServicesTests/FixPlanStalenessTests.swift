import Core
import Foundation
import Services
import Testing

// MARK: - Helpers

private func makeStalenessTestScope(
    requestedTestArtists: [String] = [],
    knownTrackCount: Int? = 10
) -> ProcessingScopeSnapshot {
    ProcessingScopeSnapshot.capture(
        requestedTestArtists: requestedTestArtists,
        knownTrackCount: knownTrackCount,
        createdAt: Date(timeIntervalSince1970: 100),
        reason: "unit-test"
    )
}

private func makeStalenessTestConfiguration(minConfidence: Int = 60) -> FixPlanConfig {
    FixPlanConfig.capture(
        configuration: AppConfiguration(),
        options: UpdateOptions(minConfidence: minConfidence),
        capturedAt: Date(timeIntervalSince1970: 100)
    )
}

private func makeStalenessTestPlan(
    scope: ProcessingScopeSnapshot,
    configuration: FixPlanConfig
) throws -> FixPlan {
    try FixPlan(
        id: FixPlanID(),
        revision: .initial,
        sourceRunID: RunID(),
        createdAt: Date(timeIntervalSince1970: 100),
        configuration: configuration,
        scope: scope,
        admission: processingAdmission(scope: scope),
        items: []
    )
}

// MARK: - Tests

@Suite("FixPlanStaleness — evaluated-on-read")
struct FixPlanStalenessTests {
    @Test("identical scope and configuration are fresh")
    func identicalScopeAndConfigurationAreFresh() throws {
        let scope = makeStalenessTestScope()
        let configuration = makeStalenessTestConfiguration()
        let plan = try makeStalenessTestPlan(scope: scope, configuration: configuration)

        let staleness = FixPlanStaleness.evaluate(plan: plan, currentScope: scope, currentConfiguration: configuration)

        #expect(!staleness.isStale)
        #expect(staleness.reasons.isEmpty)
    }

    @Test("changed test artists produce scopeChanged")
    func changedTestArtistsProduceScopeChanged() throws {
        let scope = makeStalenessTestScope(requestedTestArtists: ["Aphex Twin"])
        let configuration = makeStalenessTestConfiguration()
        let plan = try makeStalenessTestPlan(scope: scope, configuration: configuration)
        let currentScope = makeStalenessTestScope(requestedTestArtists: ["Boards of Canada"])

        let staleness = FixPlanStaleness.evaluate(
            plan: plan,
            currentScope: currentScope,
            currentConfiguration: configuration
        )

        #expect(staleness.reasons == [.scopeChanged])
    }

    @Test("testArtists to fullLibrary transition produces scopeChanged")
    func switchingFromTestArtistsToFullLibraryProducesScopeChanged() throws {
        let scope = makeStalenessTestScope(requestedTestArtists: ["Aphex Twin"])
        let configuration = makeStalenessTestConfiguration()
        let plan = try makeStalenessTestPlan(scope: scope, configuration: configuration)
        let currentScope = makeStalenessTestScope(requestedTestArtists: [])

        let staleness = FixPlanStaleness.evaluate(
            plan: plan,
            currentScope: currentScope,
            currentConfiguration: configuration
        )

        #expect(staleness.reasons == [.scopeChanged])
    }

    @Test("changed minConfidence produces configurationChanged")
    func changedMinConfidenceProducesConfigurationChanged() throws {
        let scope = makeStalenessTestScope()
        let configuration = makeStalenessTestConfiguration(minConfidence: 60)
        let plan = try makeStalenessTestPlan(scope: scope, configuration: configuration)
        let currentConfiguration = makeStalenessTestConfiguration(minConfidence: 80)

        let staleness = FixPlanStaleness.evaluate(
            plan: plan,
            currentScope: scope,
            currentConfiguration: currentConfiguration
        )

        #expect(staleness.reasons == [.configurationChanged])
    }

    @Test("track-count-only difference is NOT stale — library growth defers to a later epoch")
    func trackCountOnlyDifferenceIsNotStale() throws {
        let scope = makeStalenessTestScope(knownTrackCount: 1000)
        let configuration = makeStalenessTestConfiguration()
        let plan = try makeStalenessTestPlan(scope: scope, configuration: configuration)
        let currentScope = makeStalenessTestScope(knownTrackCount: 5000)

        // The fingerprints differ (they embed the track count)...
        #expect(scope.fingerprint != currentScope.fingerprint)
        // ...but staleness intentionally ignores knownTrackCount.
        let staleness = FixPlanStaleness.evaluate(
            plan: plan,
            currentScope: currentScope,
            currentConfiguration: configuration
        )

        #expect(!staleness.isStale)
        #expect(staleness.reasons.isEmpty)
    }

    @Test("changed Test Artists matching rule produces scopeChanged")
    func changedMatchingRuleProducesScopeChanged() throws {
        let currentScope = makeStalenessTestScope(requestedTestArtists: ["Aphex Twin"])
        let legacyScope = ProcessingScopeSnapshot(
            id: currentScope.id,
            createdAt: currentScope.createdAt,
            source: currentScope.source,
            normalizedTestArtists: currentScope.normalizedTestArtists,
            matchingRule: "effective-artist-v0",
            knownTrackCount: currentScope.knownTrackCount,
            fingerprint: currentScope.fingerprint,
            reason: currentScope.reason
        )
        let configuration = makeStalenessTestConfiguration()
        let plan = try makeStalenessTestPlan(scope: legacyScope, configuration: configuration)

        let staleness = FixPlanStaleness.evaluate(
            plan: plan,
            currentScope: currentScope,
            currentConfiguration: configuration
        )

        #expect(staleness.reasons == [.scopeChanged])
    }

    @Test("scope and configuration changes together produce both reasons")
    func scopeAndConfigurationChangesTogetherProduceBothReasons() throws {
        let scope = makeStalenessTestScope(requestedTestArtists: ["Aphex Twin"])
        let configuration = makeStalenessTestConfiguration(minConfidence: 60)
        let plan = try makeStalenessTestPlan(scope: scope, configuration: configuration)
        let currentScope = makeStalenessTestScope(requestedTestArtists: [])
        let currentConfiguration = makeStalenessTestConfiguration(minConfidence: 80)

        let staleness = FixPlanStaleness.evaluate(
            plan: plan,
            currentScope: currentScope,
            currentConfiguration: currentConfiguration
        )

        #expect(staleness.reasons == [.scopeChanged, .configurationChanged])
    }
}
