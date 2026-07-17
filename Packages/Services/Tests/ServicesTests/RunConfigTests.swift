import Core
import Foundation
import Testing
@testable import Services

@Suite("Run configuration persistence")
struct RunConfigStoreTests {
    @Test("upsert round-trips preview intent and planning transition")
    func roundTripsPreview() async throws {
        let store = try makeRunStore()
        let startedAt = Date(timeIntervalSince1970: 100)
        let finishedAt = Date(timeIntervalSince1970: 104)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: ["Aphex Twin"],
            knownTrackCount: 75,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        let record = RunRecord(
            runID: RunID(),
            requestID: RunRequestID(),
            trigger: .manualCheck,
            intent: .previewFixes,
            scope: scope,
            configuration: RunConfig(
                capturedAt: startedAt,
                writeAuthority: .readOnly,
                automation: .manualOnly,
                scopeID: scope.id,
                settings: FixPlanConfig.capture(
                    configuration: AppConfiguration(),
                    options: UpdateOptions(),
                    capturedAt: startedAt
                ),
                hadRecoveryHold: false
            ),
            transitions: [
                RunLifecycleTransition(state: .created, timestamp: startedAt),
                RunLifecycleTransition(state: .syncingLibrary, timestamp: startedAt.addingTimeInterval(1)),
                RunLifecycleTransition(state: .planningFixes, timestamp: startedAt.addingTimeInterval(2)),
                RunLifecycleTransition(state: .reporting, timestamp: startedAt.addingTimeInterval(3)),
                RunLifecycleTransition(state: .completed, timestamp: finishedAt),
            ],
            syncSummary: ActivitySyncSummary(new: 0, modified: 0, identityChanged: 0, refreshed: 0, removed: 0),
            failureMessage: nil,
            startedAt: startedAt,
            finishedAt: finishedAt
        )

        try await store.upsert(record)
        let loaded = try await store.loadAll()

        #expect(loaded == [record])
        #expect(loaded.first?.intent == .previewFixes)
        #expect(loaded.first?.configuration?.mode == .autoFix)
        #expect(loaded.first?.configuration?.writeAuthority == .readOnly)
        #expect(loaded.first?.configuration?.automation == .manualOnly)
        #expect(loaded.first?.transitions.map(\.state).contains(.planningFixes) == true)
    }

    @Test("upsert with the same run updates the open record to final")
    func updatesOpenRun() async throws {
        let store = try makeRunStore()
        let open = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .syncingLibrary,
            syncSummary: nil
        )
        let final = makeRunRecord(
            startedAt: open.startedAt,
            finishedAt: Date(timeIntervalSince1970: 104),
            state: .completedNoOp,
            syncSummary: ActivitySyncSummary(new: 0, modified: 0, identityChanged: 0, refreshed: 0, removed: 0),
            input: RunRecordInput(
                runID: open.runID,
                requestID: open.requestID,
                scope: open.scope,
                configuration: open.configuration
            )
        )

        try await store.upsert(open)
        try await store.upsert(final)
        let loaded = try await store.loadAll()

        #expect(loaded == [final])
    }

    @Test("upsert preserves the initial run configuration")
    func rejectsConfigReplacement() async throws {
        let store = try makeRunStore()
        let initial = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .syncingLibrary,
            syncSummary: nil
        )
        let replacement = makeRunRecord(
            startedAt: initial.startedAt,
            finishedAt: Date(timeIntervalSince1970: 101),
            state: .completedNoOp,
            syncSummary: nil,
            input: RunRecordInput(
                runID: initial.runID,
                requestID: initial.requestID,
                scope: initial.scope
            )
        )
        try await store.upsert(initial)

        do {
            try await store.upsert(replacement)
            Issue.record("Expected replacement run configuration to be rejected")
        } catch let RunRecordPersistenceError.invalidField(name, runID) {
            #expect(name == "configuration")
            #expect(runID == initial.runID.rawValue)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(try await store.record(for: initial.runID) == initial)
    }

    @Test("upsert rejects a configuration change outside its planning fingerprint")
    func rejectsConfigDetails() async throws {
        let store = try makeRunStore()
        let initial = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .syncingLibrary,
            syncSummary: nil
        )
        let initialConfig = try #require(initial.configuration)
        var appConfiguration = initialConfig.settings.appConfiguration
        appConfiguration.runtime.dryRun.toggle()
        let changedSettings = FixPlanConfig(
            id: initialConfig.settings.id,
            capturedAt: initialConfig.settings.capturedAt,
            appConfiguration: appConfiguration,
            options: initialConfig.settings.determinationOptions,
            hasDiscogsAccess: initialConfig.settings.hasDiscogsAccess
        )
        let changedConfig = RunConfig(
            id: initialConfig.id,
            capturedAt: initialConfig.capturedAt,
            writeAuthority: initialConfig.writeAuthority,
            automation: initialConfig.automation,
            scopeID: initialConfig.scopeID,
            settings: changedSettings,
            hadRecoveryHold: initialConfig.hadRecoveryHold
        )
        let replacement = replacing(initial, scope: initial.scope, configuration: changedConfig)
        #expect(changedConfig != initialConfig)
        try await store.upsert(initial)

        await #expect(throws: RunRecordPersistenceError.self) {
            try await store.upsert(replacement)
        }
        #expect(try await store.record(for: initial.runID) == initial)
    }

    @Test("non-finite replacement configuration fails without crashing")
    func rejectsNonFiniteConfig() async throws {
        let store = try makeRunStore()
        let initial = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .syncingLibrary,
            syncSummary: nil
        )
        let initialConfig = try #require(initial.configuration)
        var appConfiguration = initialConfig.settings.appConfiguration
        appConfiguration.runtime.retryDelaySeconds = .nan
        let changedSettings = FixPlanConfig(
            id: initialConfig.settings.id,
            capturedAt: initialConfig.settings.capturedAt,
            appConfiguration: appConfiguration,
            options: initialConfig.settings.determinationOptions,
            hasDiscogsAccess: initialConfig.settings.hasDiscogsAccess
        )
        let changedConfig = RunConfig(
            id: initialConfig.id,
            capturedAt: initialConfig.capturedAt,
            writeAuthority: initialConfig.writeAuthority,
            automation: initialConfig.automation,
            scopeID: initialConfig.scopeID,
            settings: changedSettings,
            hadRecoveryHold: initialConfig.hadRecoveryHold
        )
        try await store.upsert(initial)

        do {
            try await store.upsert(replacing(initial, scope: initial.scope, configuration: changedConfig))
            Issue.record("Expected non-finite replacement configuration to fail")
        } catch let RunRecordPersistenceError.invalidField(name, _) {
            #expect(name == "configuration")
        }
        #expect(try await store.record(for: initial.runID) == initial)
    }

    @Test("non-finite initial configuration fails with a persistence error")
    func rejectsNonFiniteInsert() async throws {
        let store = try makeRunStore()
        let record = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            state: .syncingLibrary,
            syncSummary: nil
        )
        let configuration = try #require(record.configuration)
        var appConfiguration = configuration.settings.appConfiguration
        appConfiguration.runtime.retryDelaySeconds = .nan
        let invalid = RunConfig(
            id: configuration.id,
            capturedAt: configuration.capturedAt,
            writeAuthority: configuration.writeAuthority,
            automation: configuration.automation,
            scopeID: configuration.scopeID,
            settings: FixPlanConfig(
                id: configuration.settings.id,
                capturedAt: configuration.settings.capturedAt,
                appConfiguration: appConfiguration,
                options: configuration.settings.determinationOptions
            ),
            hadRecoveryHold: configuration.hadRecoveryHold
        )

        do {
            try await store.upsert(replacing(record, scope: record.scope, configuration: invalid))
            Issue.record("Expected non-finite initial configuration to fail")
        } catch let RunRecordPersistenceError.invalidField(name, runID) {
            #expect(name == "configuration")
            #expect(runID == record.runID.rawValue)
        }
        #expect(try await store.record(for: record.runID) == nil)
    }

    @Test("upsert accepts configuration normalized by legacy exception migration")
    func updatesAfterConfigMigration() async throws {
        let store = try makeRunStore()
        let startedAt = Date(timeIntervalSince1970: 100)
        var appConfiguration = AppConfiguration()
        let exception = TrackCleaningException(artist: "Aphex Twin", album: "Selected Ambient Works")
        appConfiguration.cleaning.trackCleaningExceptions = []
        appConfiguration.exceptions.trackCleaning = [exception]
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: ["Aphex Twin"],
            knownTrackCount: 75,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        let open = makeRunRecord(
            startedAt: startedAt,
            finishedAt: nil,
            state: .syncingLibrary,
            syncSummary: nil,
            input: RunRecordInput(
                scope: scope,
                configuration: makeRunConfiguration(
                    scopeID: scope.id,
                    capturedAt: startedAt,
                    appConfiguration: appConfiguration
                )
            )
        )
        let finishedAt = startedAt.addingTimeInterval(2)
        let final = RunRecord(
            runID: open.runID,
            requestID: open.requestID,
            trigger: open.trigger,
            intent: open.intent,
            scope: open.scope,
            configuration: open.configuration,
            transitions: open.transitions + [
                RunLifecycleTransition(state: .completedNoOp, timestamp: finishedAt),
            ],
            syncSummary: open.syncSummary,
            failureMessage: nil,
            startedAt: open.startedAt,
            finishedAt: finishedAt
        )

        try await store.upsert(open)
        try await store.upsert(final)

        let stored = try #require(await store.record(for: open.runID))
        #expect(stored.state == .completedNoOp)
        #expect(stored.configuration?.settings.appConfiguration.cleaning.trackCleaningExceptions == [exception])
    }

    @Test("non-default run configuration stays equal after persistence")
    func roundTripsCustom() async throws {
        let store = try makeRunStore()
        let startedAt = Date(timeIntervalSince1970: 100.125)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: ["Aphex Twin"],
            knownTrackCount: 75,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        var appConfiguration = AppConfiguration()
        appConfiguration.cleaning.genreMappings = ["Electronic": "Electronica"]
        appConfiguration.runtime.retryDelaySeconds = 2.5
        appConfiguration.yearRetrieval.scriptAPIPriorities = [
            "default": ScriptAPIPriority(primary: ["discogs"], fallback: ["musicbrainz", "itunes"]),
        ]
        let configuration = makeRunConfiguration(
            scopeID: scope.id,
            capturedAt: startedAt,
            appConfiguration: appConfiguration,
            options: UpdateOptions(minConfidence: 73)
        )
        let record = makeRunRecord(
            startedAt: startedAt,
            finishedAt: nil,
            state: .syncingLibrary,
            syncSummary: nil,
            input: RunRecordInput(scope: scope, configuration: configuration)
        )
        try await store.upsert(record)

        try await store.upsert(record)

        #expect(try await store.record(for: record.runID)?.configuration == configuration)
    }
}
