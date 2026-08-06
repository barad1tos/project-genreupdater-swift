import Core
import Foundation
import Testing
@testable import Services

@Suite("Settings projection")
struct SettingsProjectionTests {
    @Test("legacy configuration JSON decodes with revision zero")
    func legacyJSONDecodesRevisionZero() throws {
        let configuration = try AppConfiguration.configurationDecoder()
            .decode(AppConfiguration.self, from: Data("{}".utf8))

        #expect(configuration.revision == 0)
    }

    @Test("the revision round-trips through persistence encoding")
    func revisionRoundTrips() throws {
        var configuration = AppConfiguration()
        configuration.revision = 7

        let encoded = try JSONEncoder().encode(configuration)
        let decoded = try AppConfiguration.configurationDecoder()
            .decode(AppConfiguration.self, from: encoded)

        #expect(decoded.revision == 7)
    }

    @Test("the revision never enters the fix-plan fingerprint")
    func revisionStaysOutOfFingerprint() {
        let capturedAt = Date(timeIntervalSince1970: 100)
        var oldRevision = AppConfiguration()
        oldRevision.revision = 0
        var newRevision = AppConfiguration()
        newRevision.revision = 42

        let before = FixPlanConfig.capture(
            configuration: oldRevision,
            options: UpdateOptions(),
            capturedAt: capturedAt
        )
        let after = FixPlanConfig.capture(
            configuration: newRevision,
            options: UpdateOptions(),
            capturedAt: capturedAt
        )

        // A revision bump alone must never stale a produced plan.
        #expect(before.fingerprint == after.fingerprint)
    }

    @Test("store keeps the current settings projection")
    func storesCurrentSettingsProjection() async {
        let store = ProjectionStore()
        let projection = makeProjection(settingsRevision: 3)

        await store.replaceSettingsProjection(projection)

        #expect(await store.currentSettings().settingsRevision == 3)
    }

    @Test("each replacement advances the projection revision")
    func replacementAdvancesRevision() async {
        let store = ProjectionStore()

        let first = await store.replaceSettingsProjection(makeProjection(settingsRevision: 1))
        let second = await store.replaceSettingsProjection(makeProjection(settingsRevision: 2))

        #expect(second.revision == first.revision.advanced())
    }

    @Test("a content-identical replacement preserves the revision")
    func identicalReplacementPreservesRevision() async {
        let store = ProjectionStore()

        let first = await store.replaceSettingsProjection(makeProjection(settingsRevision: 1))
        let second = await store.replaceSettingsProjection(makeProjection(settingsRevision: 1))

        #expect(second.revision == first.revision)
    }

    @Test("an older input generation cannot replace a newer projection")
    func rejectsStaleGeneration() async {
        let store = ProjectionStore()
        let older = await store.nextSettingsInputGeneration()
        let newer = await store.nextSettingsInputGeneration()

        await store.replaceSettingsProjection(makeProjection(settingsRevision: 2), inputGeneration: newer)
        let result = await store.replaceSettingsProjection(
            makeProjection(settingsRevision: 9),
            inputGeneration: older
        )

        #expect(result.settingsRevision == 2)
    }

    @Test("the updates stream yields the current projection on subscribe")
    func streamYieldsCurrentOnSubscribe() async {
        let store = ProjectionStore()
        await store.replaceSettingsProjection(makeProjection(settingsRevision: 5))

        var iterator = await store.settingsUpdates().makeAsyncIterator()
        let first = await iterator.next()

        #expect(first?.settingsRevision == 5)
    }

    private func makeProjection(settingsRevision: UInt64) -> SettingsProjection {
        var configuration = AppConfiguration()
        configuration.revision = settingsRevision
        return SettingsProjection(
            revision: .initial,
            settingsRevision: settingsRevision,
            configuration: configuration,
            saveErrorMessage: nil
        )
    }
}
