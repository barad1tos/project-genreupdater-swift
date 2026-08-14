import Core
import Foundation
import Testing
@testable import Genre_Updater
@testable import Services

@Suite("Fix plan write factory")
struct FixPlanFactoryTests {
    @Test("a free user spends one track after applying a reviewed fix plan")
    @MainActor
    func freePlanConsumesAllowance() async throws {
        let usage = MeteredTracksBox()
        let gate = FeatureGate(
            fixedTier: .free,
            usageRecorder: { usage.count += $0 }
        )
        let fixture = await makeWriteFixture(
            hasInitialRecovery: false,
            featureGate: gate
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        await fixture.script.returnChangedOutcome()

        _ = try await fixture.run(fixture.input)

        #expect(usage.count == 1)
    }

    @Test("reviewed cleaning rechecks a live tier before runtime creation")
    @MainActor
    func cleaningRechecksLiveTier() async throws {
        let tier = MutableTier(.weekPass)
        let gate = FeatureGate(
            tierProvider: { tier.value },
            freeTracksUsedProvider: { 0 },
            usageRecorder: { _ in
                // A rejected write must not reach usage metering.
            }
        )
        let fixture = await makeWriteFixture(
            hasInitialRecovery: false,
            featureGate: gate,
            changeType: .trackCleaning
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        tier.value = .free

        await #expect(throws: FeatureGateError.self) {
            _ = try await fixture.run(fixture.input)
        }
        #expect(await fixture.runtime.callCount == 0)
        #expect(await fixture.script.fetchCalls.isEmpty)
    }

    @Test("Fix plan writer enforces recovery admission")
    @MainActor
    func enforcesRecovery() async throws {
        let fixture = await makeWriteFixture(hasInitialRecovery: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        await #expect(throws: WriteAdmissionError.self) {
            _ = try await fixture.run(fixture.input)
        }
        #expect(await fixture.script.fetchCalls.isEmpty)

        await fixture.script.returnUnknownOutcome()
        await #expect(throws: AppleScriptOutcomeError.self) {
            _ = try await fixture.run(fixture.input)
        }
        #expect(await fixture.script.fetchCalls.map(\.batchSize) == [7])
        #expect(await fixture.script.fetchCalls.map(\.timeout) == [.seconds(45)])
        let recoveryID = try #require(await fixture.processor.recoveryHoldID())
        let fetchCount = await fixture.script.fetchCalls.count
        await #expect(throws: BatchProcessorError.self) {
            _ = try await fixture.run(fixture.input)
        }
        #expect(await fixture.script.fetchCalls.count == fetchCount)
        try await fixture.processor.clearRecovery(batchID: recoveryID)
    }

    @Test(
        "Fix plan writer rejects every stale write contract",
        arguments: StaleInputMutation.allCases
    )
    @MainActor
    fileprivate func rejectsStaleInput(_ mutation: StaleInputMutation) async {
        let fixture = await makeWriteFixture(hasInitialRecovery: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let input = mutation.applying(to: fixture.input)

        do {
            _ = try await fixture.run(input)
            Issue.record("Expected stale fix plan input")
        } catch let error as FixPlanWrite.Failure {
            guard case .staleInput = error else {
                Issue.record("Expected staleInput, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected FixPlanWrite.Failure, got \(error)")
        }
        #expect(await fixture.runtime.callCount == 0)
        #expect(await fixture.script.fetchCalls.isEmpty)
    }

    @Test("a landed write attributes its entries to the run it received")
    @MainActor
    func attributesEntriesToTheReceivedRun() async throws {
        let fixture = await makeWriteFixture(hasInitialRecovery: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        await fixture.script.returnChangedOutcome()
        let runID = RunID()

        let result = try await fixture.write(fixture.input, runID) { _ in
            // Attribution pin; checkpoint assertions live in Services tests.
        }

        // Pins the makeRunner glue: the received run reaches the coordinator
        // BEFORE changes apply, so persisted entries carry it.
        #expect(result.entries.first?.runID == runID.rawValue)
        #expect(await fixture.coordinator.runAttribution() == runID)
    }

    @Test("orchestrator closes work when the real writer rejects stale input")
    @MainActor
    func closesStaleWork() async {
        let fixture = await makeWriteFixture(hasInitialRecovery: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let input = StaleInputMutation.scope.applying(to: fixture.input)
        let capture = RunCapture()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { await capture.append($0) },
            write: .init(writeFixPlan: fixture.write),
            now: { Date(timeIntervalSince1970: 120) }
        ))

        let result = await orchestrator.submit(.manualWrite(input: input))

        guard case let .failed(snapshot) = result else {
            Issue.record("Expected failed run for stale write input")
            return
        }
        #expect(snapshot.finishedAt != nil)
        #expect(snapshot.workItems.allSatisfy { $0.state == .outcome(.failed) })
        #expect(await capture.last?.workItems.allSatisfy {
            $0.state == .outcome(.failed)
        } == true)
        #expect(await fixture.runtime.callCount == 0)
        #expect(await fixture.script.fetchCalls.isEmpty)
    }
}

private enum StaleInputMutation: CaseIterable, Equatable {
    case scope
    case authority
    case scopeID
    case settings
    case workItems

    func applying(to input: FixPlanWriteInput) -> FixPlanWriteInput {
        let scope = switch self {
        case .scope: alteredScope(input.scope)
        case .authority, .scopeID, .settings, .workItems: input.scope
        }
        let configuration = switch self {
        case .authority:
            alteredConfiguration(input.configuration, writeAuthority: .readOnly)
        case .scopeID:
            alteredConfiguration(input.configuration, scopeID: UUID())
        case .settings:
            alteredConfiguration(input.configuration, settings: alteredSettings(input.configuration.settings))
        case .scope, .workItems:
            input.configuration
        }
        let workItems = self == .workItems ? [] : input.workItems
        return FixPlanWriteInput(
            target: input.target,
            scope: scope,
            configuration: configuration,
            workItems: workItems
        )
    }

    private func alteredScope(_ scope: ProcessingScopeSnapshot) -> ProcessingScopeSnapshot {
        ProcessingScopeSnapshot(
            id: scope.id,
            createdAt: scope.createdAt,
            source: .testArtists,
            normalizedTestArtists: ["Other Artist"],
            matchingRule: scope.matchingRule,
            knownTrackCount: scope.knownTrackCount,
            fingerprint: "altered-scope",
            reason: scope.reason
        )
    }

    private func alteredConfiguration(
        _ configuration: RunConfig,
        writeAuthority: WriteAuthority? = nil,
        scopeID: UUID? = nil,
        settings: FixPlanConfig? = nil
    ) -> RunConfig {
        RunConfig(
            id: configuration.id,
            capturedAt: configuration.capturedAt,
            writeAuthority: writeAuthority ?? configuration.writeAuthority,
            automation: configuration.automation,
            scopeID: scopeID ?? configuration.scopeID,
            settings: settings ?? configuration.settings,
            hadRecoveryHold: configuration.hadRecoveryHold
        )
    }

    private func alteredSettings(_ settings: FixPlanConfig) -> FixPlanConfig {
        var configuration = settings.appConfiguration
        configuration.applescript.batchProcessing.idsBatchSize += 1
        return FixPlanConfig.capture(
            configuration: configuration,
            options: settings.determinationOptions,
            capturedAt: settings.capturedAt,
            hasDiscogsAccess: settings.hasDiscogsAccess
        )
    }
}

private struct WriteFixture {
    let input: FixPlanWriteInput
    let script: ScriptSpy
    let processor: BatchProcessor
    let runtime: RuntimeProbe
    let coordinator: UpdateCoordinator
    let write: @Sendable (
        FixPlanWriteInput,
        RunID,
        @escaping WorkCheckpointSink
    ) async throws -> BatchUpdateResult
    let directory: URL

    func run(_ input: FixPlanWriteInput) async throws -> BatchUpdateResult {
        try await write(input, RunID()) { _ in
            // Direct writer tests assert results; Services checkpoint tests own checkpoint assertions.
        }
    }
}

@MainActor
private func makeWriteFixture(
    hasInitialRecovery: Bool,
    featureGate: FeatureGate? = nil,
    changeType: ChangeType = .genreUpdate
) async -> WriteFixture {
    let item = makeItem(changeType: changeType)
    let plan = makePlan(item)
    let decision = FixPlanReviewDecision(
        planID: plan.id,
        planRevision: plan.revision,
        revision: .initial,
        decidedAt: Date(timeIntervalSince1970: 110),
        itemDecisions: [FixPlanItemDecision(itemID: item.id, verdict: .accepted)]
    )
    let store = FactoryPlanStore(plan: plan, decision: decision)
    let script = ScriptSpy()
    await script.setTracks([writeTrack()])
    let mapper = TrackIDMapper()
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("FixPlanFactoryTests-\(UUID().uuidString)")
    let processor = BatchProcessor(
        checkpointManager: CheckpointManager(directory: directory),
        featureGate: featureGate ?? FeatureGate(fixedTier: .pro)
    )
    let coordinator = makeCoordinator(script: script, mapper: mapper, directory: directory)
    let recovery = RecoveryProbe(isHeld: hasInitialRecovery)
    let runtime = RuntimeProbe()
    let write = FixPlanWrite.makeRunner(FixPlanWrite.RunnerDependencies(
        fixPlanStore: store,
        mapper: mapper,
        batchProcessor: processor,
        makeRuntime: { configuration, scope in
            #expect(configuration == plan.configuration)
            #expect(scope == plan.scope)
            await runtime.record()
            return FixPlanWrite.Runtime(coordinator: coordinator, scripts: script)
        },
        hasRunRecovery: { await recovery.check() }
    ))
    let input = makeWriteInput(plan: plan, decision: decision)
    return WriteFixture(
        input: input,
        script: script,
        processor: processor,
        runtime: runtime,
        coordinator: coordinator,
        write: write,
        directory: directory
    )
}

private func makeWriteInput(plan: FixPlan, decision: FixPlanReviewDecision) -> FixPlanWriteInput {
    FixPlanWriteInput(
        target: FixPlanWriteTarget(
            planID: plan.id,
            planRevision: plan.revision,
            decisionRevision: decision.revision
        ),
        scope: plan.scope,
        configuration: RunConfig(
            capturedAt: decision.decidedAt,
            writeAuthority: .reviewedPlan,
            automation: .manualOnly,
            scopeID: plan.scope.id,
            settings: plan.configuration,
            hadRecoveryHold: false
        ),
        workItems: plan.items.map(RunWorkItem.init(item:))
    )
}

private func makeCoordinator(
    script: ScriptSpy,
    mapper: TrackIDMapper,
    directory: URL
) -> UpdateCoordinator {
    let api = DashboardStateAPIService()
    return UpdateCoordinator(
        dependencies: UpdateDependencies(
            apiOrchestrator: APIOrchestrator(services: APIOrchestratorServices(
                musicBrainz: api,
                discogs: api,
                appleMusic: api
            )),
            scriptBridge: script,
            stores: .init(trackStore: FactoryTrackStore(), cache: FactoryCache()),
            undoCoordinator: UndoCoordinator(
                scriptBridge: script,
                directory: directory
            ),
            idMapper: mapper
        ),
        genreDeterminator: GenreDeterminator(),
        runtimeConfiguration: UpdateRuntimeConfiguration(areBatchUpdatesEnabled: false)
    )
}

private func writeTrack() -> Track {
    Track(
        id: "AS-1",
        name: "Track 1",
        artist: "Artist",
        album: "Album",
        genre: "Rock",
        trackStatus: TrackKind.subscription.rawValue,
        appleScriptID: "AS-1"
    )
}

private func makeItem(changeType: ChangeType = .genreUpdate) -> FixPlanItem {
    FixPlanItem(
        id: UUID(),
        identity: FixPlanItemIdentity(
            readID: "MK-1",
            appleScriptID: "AS-1",
            artist: "Artist",
            album: "Album",
            trackName: "Track 1"
        ),
        changeType: changeType,
        oldValue: "Rock",
        newValue: "Metal",
        confidence: 90,
        source: "review-test"
    )
}

@MainActor
private final class MutableTier {
    var value: Tier

    init(_ value: Tier) {
        self.value = value
    }
}

private func makePlan(_ item: FixPlanItem) -> FixPlan {
    let capturedAt = Date(timeIntervalSince1970: 100)
    var configuration = AppConfiguration()
    configuration.applescript.batchProcessing.idsBatchSize = 7
    configuration.applescript.timeouts.idsBatchFetch = .seconds(45)
    return FixPlan(
        id: FixPlanID(),
        revision: .initial,
        sourceRunID: RunID(),
        createdAt: capturedAt,
        configuration: FixPlanConfig.capture(
            configuration: configuration,
            options: UpdateOptions(),
            capturedAt: capturedAt
        ),
        scope: ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: capturedAt,
            reason: "unit-test"
        ),
        items: [item]
    )
}
