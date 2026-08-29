import Core
import Foundation
import Testing
@testable import Genre_Updater
@testable import Services

@Suite("Fix plan write factory")
struct FixPlanFactoryTests {
    @Test("automatic plan authority uses the canonical fix-plan writer")
    @MainActor
    func automaticPlanUsesCanonicalWriter() async throws {
        let fixture = await makeWriteFixture(hasInitialRecovery: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        await fixture.script.returnChangedOutcome()
        let reviewed = fixture.input.configuration
        let automatic = FixPlanWriteInput(
            target: fixture.input.target,
            scope: fixture.input.scope,
            admission: fixture.input.admission,
            configuration: RunConfig(
                id: reviewed.id,
                capturedAt: reviewed.capturedAt,
                mode: .autoFix,
                writeAuthority: .automaticPlan,
                automation: .hybrid,
                scopeID: reviewed.scopeID,
                settings: reviewed.settings,
                hadRecoveryHold: false
            ),
            workItems: fixture.input.workItems
        )

        let result = try await fixture.run(automatic)

        #expect(result.entries.count == 1)
        #expect(await fixture.runtime.callCount == 1)
    }

    @Test("automatic input builder preserves plan lineage and processing policy")
    @MainActor
    func automaticBuilderPreservesLineage() async throws {
        let item = makeItem()
        let plan = makePlan(item)
        let decision = FixPlanReviewer.initialDecision(
            for: plan,
            at: Date(timeIntervalSince1970: 110)
        )
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { configuration in _ = configuration }
        )
        dependencies.configureLibraryPersistenceForTesting(
            fixPlanStore: FactoryPlanStore(plan: plan, decision: decision)
        )
        dependencies.installTestFeatureGate(FeatureGate(fixedTier: .pro))
        let planning = RunConfig(
            capturedAt: Date(timeIntervalSince1970: 100),
            mode: .autoFix,
            writeAuthority: .readOnly,
            automation: .hybrid,
            scopeID: plan.scope.id,
            settings: plan.configuration,
            hadRecoveryHold: false
        )

        let input = try await dependencies.makeAutomaticWriteBuilder()(
            plan.id,
            planning,
            .backgroundSync
        )

        #expect(input.target.planID == plan.id)
        #expect(input.target.planRevision == plan.revision)
        #expect(input.target.decisionRevision == decision.revision)
        #expect(input.scope == plan.scope)
        #expect(input.configuration.mode == .autoFix)
        #expect(input.configuration.writeAuthority == .automaticPlan)
        #expect(input.configuration.automation == .hybrid)
        let request = RunRequest.automaticWrite(trigger: .backgroundSync, input: input)
        #expect(request.writeInput?.requiredAdmissionFeature == .autoSync)
        #expect(input.workItems.map(\.id) == plan.items.map(\.id))
    }

    @Test("background automatic write rechecks entitlement at reservation")
    @MainActor
    func automaticWriteRechecksEntitlement() async throws {
        let tier = MutableTier(.pro)
        let gate = FeatureGate(
            tierProvider: { tier.value },
            freeTracksUsedProvider: { 0 },
            usageRecorder: { trackCount in _ = trackCount }
        )
        let fixture = await makeWriteFixture(
            hasInitialRecovery: false,
            featureGate: gate
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let baseInput = FixPlanWriteInput(
            target: fixture.input.target,
            scope: fixture.input.scope,
            admission: fixture.input.admission,
            configuration: fixture.input.configuration,
            workItems: fixture.input.workItems
        )
        let request = RunRequest.automaticWrite(trigger: .backgroundSync, input: baseInput)
        let input = try #require(request.writeInput)
        tier.value = .free

        await #expect(throws: FeatureGateError.self) {
            _ = try await fixture.run(input)
        }
        #expect(await fixture.runtime.callCount == 0)
        #expect(await fixture.script.metadataFetches.isEmpty)
    }

    @Test("background automatic input rechecks the live automation entitlement")
    @MainActor
    func automaticBuilderRechecksEntitlement() async throws {
        let item = makeItem()
        let plan = makePlan(item)
        let decision = FixPlanReviewer.initialDecision(
            for: plan,
            at: Date(timeIntervalSince1970: 110)
        )
        let tier = MutableTier(.pro)
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { configuration in _ = configuration }
        )
        dependencies.configureLibraryPersistenceForTesting(
            fixPlanStore: FactoryPlanStore(plan: plan, decision: decision)
        )
        dependencies.installTestFeatureGate(FeatureGate(
            tierProvider: { tier.value },
            freeTracksUsedProvider: { 0 },
            usageRecorder: { trackCount in _ = trackCount }
        ))
        let builder = dependencies.makeAutomaticWriteBuilder()
        tier.value = .free

        await #expect(throws: FeatureGateError.self) {
            _ = try await builder(
                plan.id,
                RunConfig(
                    capturedAt: Date(timeIntervalSince1970: 100),
                    mode: .autoFix,
                    writeAuthority: .readOnly,
                    automation: .scheduled,
                    scopeID: plan.scope.id,
                    settings: plan.configuration,
                    hadRecoveryHold: false
                ),
                .backgroundSync
            )
        }
    }

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
        #expect(await fixture.script.metadataFetches.isEmpty)
    }

    @Test("Fix plan writer enforces recovery admission")
    @MainActor
    func enforcesRecovery() async throws {
        let fixture = await makeWriteFixture(hasInitialRecovery: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        await #expect(throws: WriteAdmissionError.self) {
            _ = try await fixture.run(fixture.input)
        }
        #expect(await fixture.script.metadataFetches.isEmpty)

        await fixture.script.returnUnknownOutcome()
        await #expect(throws: AppleScriptOutcomeError.self) {
            _ = try await fixture.run(fixture.input)
        }
        let databaseID = try #require(MusicDatabaseTrackID(rawValue: "AS-1"))
        #expect(await fixture.script.metadataFetches == [[databaseID]])
        let recoveryID = try #require(await fixture.processor.recoveryHoldID())
        let fetchCount = await fixture.script.metadataFetches.count
        await #expect(throws: BatchProcessorError.self) {
            _ = try await fixture.run(fixture.input)
        }
        #expect(await fixture.script.metadataFetches.count == fetchCount)
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
        #expect(await fixture.script.metadataFetches.isEmpty)
    }

    @Test("Fix plan writer rejects admission evidence from another certificate")
    @MainActor
    func rejectsMismatchedAdmission() async {
        let fixture = await makeWriteFixture(hasInitialRecovery: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let input = FixPlanWriteInput(
            target: fixture.input.target,
            scope: fixture.input.scope,
            admission: replacingCertificate(in: fixture.input.admission),
            configuration: fixture.input.configuration,
            workItems: fixture.input.workItems
        )

        await #expect(throws: FixPlanWrite.Failure.self) {
            _ = try await fixture.run(input)
        }

        #expect(await fixture.runtime.callCount == 0)
        #expect(await fixture.script.metadataFetches.isEmpty)
    }

    @Test("Fix plan writer revalidates its exact certificate as a subset")
    @MainActor
    func revalidatesExactCertificateAsSubset() async throws {
        let fixture = await makeWriteFixture(hasInitialRecovery: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        await fixture.script.returnChangedOutcome()

        _ = try await fixture.run(fixture.input)

        let validation = try #require(await fixture.validation.calls.first)
        #expect(await fixture.validation.calls.count == 1)
        #expect(validation.admission == fixture.input.admission)
        #expect(validation.candidates.map(\.id) == ["AS-1"])
        #expect(validation.match == .subset)
    }

    @Test("Replaced plan certificate stops before runtime and recovery")
    @MainActor
    func replacedCertificateStopsBeforeRuntimeAndRecovery() async throws {
        let fixture = await makeWriteFixture(
            hasInitialRecovery: false,
            rejectsAdmission: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        await #expect(throws: FactoryAdmissionError.self) {
            _ = try await fixture.run(fixture.input)
        }

        #expect(await fixture.validation.calls.count == 1)
        #expect(await fixture.runtime.callCount == 0)
        #expect(await fixture.script.metadataFetches.isEmpty)
        #expect(await fixture.processor.recoveryHoldID() == nil)
    }

    @Test(
        "Certificate replacement while queued stops eventual writes",
        arguments: QueuedAdmissionPath.allCases
    )
    @MainActor
    func queuedAdmissionFails(_ path: QueuedAdmissionPath) async throws {
        let fixture = await makeWriteFixture(hasInitialRecovery: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let request = try path.request(input: fixture.input)
        let holdID = UUID()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { _ in SyncResult() },
            persistRunRecord: { _ in
                // Persistence is outside this queued-admission boundary test.
            },
            write: .init(writeFixPlan: fixture.write),
            currentDecisionTarget: { _ in fixture.input.target }
        ))
        await orchestrator.restoreRecoveryHold(id: holdID)
        _ = await orchestrator.submit(request)
        await fixture.validation.rejectAdmission()
        _ = await orchestrator.resolveRecovery(
            id: holdID,
            runID: nil,
            at: Date(timeIntervalSince1970: 300)
        )

        let release = await orchestrator.releaseQueuedWrite()

        guard case let .released(.failed(snapshot)) = release else {
            Issue.record("Expected queued write to fail admission, got \(release)")
            return
        }
        #expect(snapshot.finishedAt != nil)
        #expect(snapshot.workItems.allSatisfy { $0.state == .outcome(.failed) })
        #expect(await fixture.validation.calls.count == 1)
        #expect(await fixture.runtime.callCount == 0)
        #expect(await fixture.script.metadataFetches.isEmpty)
        #expect(await fixture.processor.recoveryHoldID() == nil)
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
            synchronizeLibrary: { _ in SyncResult() },
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
        #expect(await fixture.script.metadataFetches.isEmpty)
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
            admission: input.admission,
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

enum QueuedAdmissionPath: CaseIterable {
    case manual
    case continuation

    func request(input: FixPlanWriteInput) throws -> RunRequest {
        switch self {
        case .manual:
            .manualWrite(input: input)
        case .continuation:
            try .continuation(of: sourceRecord(input: input), input: input)
        }
    }

    private func sourceRecord(input: FixPlanWriteInput) throws -> RunRecord {
        let startedAt = Date(timeIntervalSince1970: 100)
        let failedItems = try input.workItems.map {
            try $0.transition(to: .outcome(.failed), detail: "Retryable failure")
        }
        return RunRecord(
            header: .init(
                runID: RunID(),
                requestID: RunRequestID(),
                trigger: .manualCheck,
                intent: .writeFixes,
                scope: input.scope,
                continuesRunID: nil,
                startedAt: startedAt
            ),
            configuration: input.configuration,
            writeTarget: input.target,
            transitions: [
                RunLifecycleTransition(state: .cancelled, timestamp: startedAt.addingTimeInterval(5)),
            ],
            workItems: failedItems,
            status: .init(
                syncSummary: nil,
                failureMessage: nil,
                finishedAt: startedAt.addingTimeInterval(5)
            )
        )
    }
}

private struct WriteFixture {
    let input: FixPlanWriteInput
    let script: ScriptSpy
    let processor: BatchProcessor
    let runtime: RuntimeProbe
    let validation: AdmissionValidationProbe
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
    changeType: ChangeType = .genreUpdate,
    rejectsAdmission: Bool = false
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
    let validation = AdmissionValidationProbe(rejectsAdmission: rejectsAdmission)
    let write = FixPlanWrite.makeRunner(FixPlanWrite.RunnerDependencies(
        fixPlanStore: store,
        mapper: mapper,
        batchProcessor: processor,
        validateProcessing: { admission, candidates, match in
            try await validation.validate(admission, candidates: candidates, match: match)
        },
        makeRuntime: { configuration, scope in
            #expect(configuration == plan.configuration)
            #expect(scope == plan.scope)
            await runtime.record()
            return FixPlanWrite.Runtime(coordinator: coordinator, verifier: script)
        },
        hasRunRecovery: { await recovery.check() }
    ))
    let input = makeWriteInput(plan: plan, decision: decision)
    return WriteFixture(
        input: input,
        script: script,
        processor: processor,
        runtime: runtime,
        validation: validation,
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
        admission: certifiedAdmission(from: plan),
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
            writer: script,
            stores: .init(trackStore: FactoryTrackStore(), cache: FactoryCache()),
            undoCoordinator: UndoCoordinator(
                musicApp: script,
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
            readID: "AS-1",
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
    let scope = ProcessingScopeSnapshot.capture(
        requestedTestArtists: [],
        knownTrackCount: 1,
        createdAt: capturedAt,
        reason: "unit-test"
    )
    guard let membership = try? MembershipFingerprint.make(ids: [testMusicDatabaseID("AS-1")]) else {
        preconditionFailure("Factory admission membership must be valid")
    }
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
                trackCount: 1
            ),
            observedAt: capturedAt
        ),
        maximumMetadataAge: nil
    )
    return FixPlan(restoring: .init(
        id: FixPlanID(),
        revision: .initial,
        sourceRunID: RunID(),
        createdAt: capturedAt,
        configuration: FixPlanConfig.capture(
            configuration: configuration,
            options: UpdateOptions(),
            capturedAt: capturedAt
        ),
        scope: scope,
        admission: .certified(admission),
        items: [item]
    ))
}

private func certifiedAdmission(from plan: FixPlan) -> ProcessingAdmission {
    guard case let .certified(admission) = plan.admission else {
        preconditionFailure("Factory write plans must be certified")
    }
    return admission
}

private func replacingCertificate(in admission: ProcessingAdmission) -> ProcessingAdmission {
    let certificate = admission.certificate
    return ProcessingAdmission(
        scopeID: admission.scopeID,
        certificate: ScopeCertificate(
            id: UUID(),
            revision: certificate.revision,
            membership: certificate.membership,
            testArtists: certificate.normalizedTestArtists,
            fieldSet: certificate.fieldSet,
            evidence: certificate.evidence,
            observedAt: certificate.observedAt
        ),
        maximumMetadataAge: admission.maximumMetadataAge
    )
}

private actor AdmissionValidationProbe {
    struct Call: Sendable {
        let admission: ProcessingAdmission
        let candidates: [Track]
        let match: AdmissionTrackMatch
    }

    private var rejectsAdmission: Bool
    private(set) var calls: [Call] = []

    init(rejectsAdmission: Bool) {
        self.rejectsAdmission = rejectsAdmission
    }

    func rejectAdmission() {
        rejectsAdmission = true
    }

    func validate(
        _ admission: ProcessingAdmission,
        candidates: [Track],
        match: AdmissionTrackMatch
    ) throws {
        calls.append(Call(admission: admission, candidates: candidates, match: match))
        if rejectsAdmission {
            throw FactoryAdmissionError.replaced
        }
    }
}

private enum FactoryAdmissionError: Error {
    case replaced
}
