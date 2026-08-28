import Core
import Foundation
import Testing
@testable import Services

@Suite("Automatic plan writes")
struct AutomaticWriteTests {
    @Test(
        "write factories derive admission provenance",
        arguments: AdmissionFactoryCase.allCases
    )
    private func pinsAdmissionProvenance(_ factory: AdmissionFactoryCase) throws {
        let input = admissionInput(authority: factory.authority)

        let request = try factory.makeRequest(input)

        #expect(request.writeInput?.requiredAdmissionFeature == factory.expectedFeature)
    }

    @Test("explicit preview persists its captured processing policy")
    func explicitPreviewPersistsPolicy() async throws {
        let records = RunRecordProbe()
        let capturedAt = Date(timeIntervalSince1970: 100)
        let configuration = FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(),
            capturedAt: capturedAt
        )
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            produceFixPlan: { _, _, _ in .empty },
            now: { capturedAt }
        ))

        let result = await orchestrator.submit(.preview(
            trigger: .manualCheck,
            configuration: configuration,
            mode: .preview,
            automation: .hybrid,
            requestedTestArtists: [],
            knownTrackCount: 75
        ))

        #expect(result.lifecycle?.configuration?.mode == .preview)
        #expect(result.lifecycle?.configuration?.writeAuthority == .readOnly)
        #expect(result.lifecycle?.configuration?.automation == .hybrid)
        let final = try #require(await records.records.last)
        #expect(final.configuration == result.lifecycle?.configuration)
    }

    @Test("auto-fix planning chains a durable automatic plan write")
    func autoFixChainsAutomaticWrite() async {
        let records = RunRecordProbe()
        let processing = ProcessingSuccessProbe()
        let planID = FixPlanID()
        let capturedAt = Date(timeIntervalSince1970: 100)
        let configuration = FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(),
            capturedAt: capturedAt
        )
        let writeProbe = WriteProbe(result: BatchUpdateResult(
            entries: [writeEntry()],
            failedTrackIDs: [],
            errorDescriptions: []
        ))
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            produceFixPlan: { _, _, _ in
                FixPlanProduction(planID: planID, proposalCount: 1)
            },
            prepareAutomaticWrite: { producedPlanID, planning, _ in
                automaticInput(planID: producedPlanID, planning: planning, capturedAt: capturedAt)
            },
            write: .init(writeFixPlan: { input, _, checkpoint in
                try await checkpointWrite(input, using: checkpoint)
                return try await writeProbe.apply(input: input)
            }),
            recordSuccessfulProcessing: { await processing.record() },
            now: { capturedAt }
        ))

        let result = await orchestrator.submit(.preview(
            trigger: .backgroundSync,
            configuration: configuration,
            mode: .autoFix,
            automation: .hybrid,
            requestedTestArtists: [],
            knownTrackCount: 75
        ))

        #expect(result.lifecycle?.intent == .writeFixes)
        #expect(result.lifecycle?.state == .completed)
        let finished = await records.records.filter { $0.finishedAt != nil }
        #expect(finished.map(\.intent) == [.previewFixes, .writeFixes])
        #expect(finished.first?.configuration?.mode == .autoFix)
        #expect(finished.last?.configuration?.writeAuthority == .automaticPlan)
        #expect(finished.last?.configuration?.automation == .hybrid)
        #expect(finished.last?.writeTarget?.planID == planID)
        #expect(await writeProbe.calls.count == 1)
        #expect(await processing.callCount == 1)
    }

    @Test(
        "automatic write rejects mismatched planning provenance",
        arguments: AutomaticInputMutation.allCases
    )
    private func rejectsMismatchedInput(_ mutation: AutomaticInputMutation) async {
        let planID = FixPlanID()
        let capturedAt = Date(timeIntervalSince1970: 100)
        let settings = FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(),
            capturedAt: capturedAt
        )
        let writeProbe = WriteProbe(result: BatchUpdateResult(
            entries: [writeEntry()],
            failedTrackIDs: [],
            errorDescriptions: []
        ))
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: ignoreRunRecord,
            produceFixPlan: { _, _, _ in
                FixPlanProduction(planID: planID, proposalCount: 1)
            },
            prepareAutomaticWrite: { producedPlanID, planning, _ in
                mutation.applying(to: automaticInput(
                    planID: producedPlanID,
                    planning: planning,
                    capturedAt: capturedAt
                ))
            },
            write: .init(writeFixPlan: { input, _, checkpoint in
                try await checkpointWrite(input, using: checkpoint)
                return try await writeProbe.apply(input: input)
            }),
            now: { capturedAt }
        ))

        let result = await orchestrator.submit(.preview(
            trigger: .backgroundSync,
            configuration: settings,
            mode: .autoFix,
            automation: .scheduled,
            requestedTestArtists: [],
            knownTrackCount: 75
        ))

        #expect(result.lifecycle?.state == .failed)
        #expect(result.lifecycle?.failureMessage == "Automatic fix-plan write input does not match the captured plan")
        #expect(await writeProbe.calls.isEmpty)
    }

    @Test("auto-fix does not write without a durable planning result")
    func autoFixRequiresDurablePlanRecord() async {
        let records = FailingRecordProbe(failingCall: 2)
        let processing = ProcessingSuccessProbe()
        let planID = FixPlanID()
        let capturedAt = Date(timeIntervalSince1970: 100)
        let configuration = FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(),
            capturedAt: capturedAt
        )
        let writeProbe = WriteProbe(result: BatchUpdateResult(
            entries: [],
            failedTrackIDs: [],
            errorDescriptions: []
        ))
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            produceFixPlan: { _, _, _ in
                FixPlanProduction(planID: planID, proposalCount: 1)
            },
            prepareAutomaticWrite: { producedPlanID, planning, _ in
                automaticInput(planID: producedPlanID, planning: planning, capturedAt: capturedAt)
            },
            write: .init(writeFixPlan: { input, _, _ in
                try await writeProbe.apply(input: input)
            }),
            recordSuccessfulProcessing: { await processing.record() },
            now: { capturedAt }
        ))

        let result = await orchestrator.submit(.preview(
            trigger: .backgroundSync,
            configuration: configuration,
            mode: .autoFix,
            automation: .hybrid,
            requestedTestArtists: [],
            knownTrackCount: 75
        ))

        #expect(result.lifecycle?.state == .failed)
        #expect(result.lifecycle?.failureMessage == "Fix plan result could not persist its terminal record")
        #expect(await writeProbe.calls.isEmpty)
        #expect(await processing.callCount == 0)
    }

    @Test("manual work outranks a scheduled automatic write after planning")
    func manualRequestPrecedesScheduledWrite() async {
        let records = RunRecordProbe()
        let planningGate = SyncGate()
        let planID = FixPlanID()
        let capturedAt = Date(timeIntervalSince1970: 100)
        let backgroundConfiguration = planConfiguration(capturedAt: capturedAt)
        let manualConfiguration = planConfiguration(
            capturedAt: capturedAt,
            options: UpdateOptions(minConfidence: 80)
        )
        let writeProbe = WriteProbe(result: BatchUpdateResult(
            entries: [writeEntry()],
            failedTrackIDs: [],
            errorDescriptions: []
        ))
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            produceFixPlan: { _, _, configuration in
                if configuration.id == backgroundConfiguration.id {
                    await planningGate.waitUntilReleased()
                    return FixPlanProduction(planID: planID, proposalCount: 1)
                }
                return .empty
            },
            prepareAutomaticWrite: { producedPlanID, planning, _ in
                automaticInput(planID: producedPlanID, planning: planning, capturedAt: capturedAt)
            },
            write: .init(writeFixPlan: { input, _, checkpoint in
                try await checkpointWrite(input, using: checkpoint)
                return try await writeProbe.apply(input: input)
            }),
            now: { capturedAt }
        ))

        let scheduled = Task {
            await orchestrator.submit(.preview(
                trigger: .backgroundSync,
                configuration: backgroundConfiguration,
                mode: .autoFix,
                automation: .scheduled,
                requestedTestArtists: [],
                knownTrackCount: 75
            ))
        }
        await planningGate.waitUntilEntered()
        let manual = await orchestrator.submit(.preview(
            trigger: .manualCheck,
            configuration: manualConfiguration,
            mode: .preview,
            requestedTestArtists: [],
            knownTrackCount: 75
        ))
        await planningGate.release()
        let scheduledResult = await scheduled.value
        await records.waitUntilFinished(count: 3)

        #expect(manual.lifecycle?.state == .planningFixes)
        #expect(scheduledResult.lifecycle?.trigger == .manualCheck)
        #expect(scheduledResult.isQueued)
        let finished = await records.records.filter { $0.finishedAt != nil }
        #expect(finished.map(\.trigger) == [.backgroundSync, .manualCheck, .backgroundSync])
        #expect(finished.map(\.intent) == [.previewFixes, .previewFixes, .writeFixes])
    }

    @Test(
        "newer mutating runs discard an older scheduled plan",
        arguments: SupersedingRun.allCases
    )
    private func mutationInvalidatesPlan(_ supersedingRun: SupersedingRun) async {
        let fixture = stalePlanFixture()

        let scheduled = Task {
            await fixture.orchestrator.submit(.preview(
                trigger: .backgroundSync,
                configuration: fixture.scheduledConfiguration,
                mode: .autoFix,
                automation: .scheduled,
                requestedTestArtists: [],
                knownTrackCount: 75
            ))
        }
        await fixture.planningGate.waitUntilEntered()
        switch supersedingRun {
        case .autoFix:
            _ = await fixture.orchestrator.submit(.preview(
                trigger: .manualCheck,
                configuration: fixture.manualConfiguration,
                mode: .autoFix,
                requestedTestArtists: [],
                knownTrackCount: 75
            ))
        case .batch:
            let scope = ProcessingScopeSnapshot.capture(
                requestedTestArtists: [],
                knownTrackCount: 75,
                createdAt: Date(timeIntervalSince1970: 100),
                reason: "automatic-write-superseding-batch"
            )
            _ = await fixture.orchestrator.submit(.manualBatchUpdate(
                input: BatchRunInput(
                    options: UpdateOptions(),
                    trackCount: 75,
                    admission: processingAdmission(scope: scope)
                ),
                requestedTestArtists: [],
                knownTrackCount: 75
            ))
        }
        await fixture.planningGate.release()
        let scheduledResult = await scheduled.value
        let finishedCount = supersedingRun == .autoFix ? 3 : 2
        await fixture.records.waitUntilFinished(count: finishedCount)

        guard case let .completed(scheduledLifecycle) = scheduledResult else {
            Issue.record("Expected the superseded scheduled plan to complete without writing")
            return
        }
        #expect(scheduledLifecycle.trigger == .backgroundSync)
        #expect(scheduledLifecycle.intent == .previewFixes)
        let finished = await fixture.records.records.filter { $0.finishedAt != nil }
        switch supersedingRun {
        case .autoFix:
            #expect(finished.map(\.intent) == [.previewFixes, .previewFixes, .writeFixes])
            #expect(await fixture.writeProbe.calls.map(\.target.planID) == [fixture.manualPlanID])
        case .batch:
            #expect(finished.map(\.intent) == [.previewFixes, .batchUpdate])
            #expect(await fixture.writeProbe.calls.isEmpty)
        }
    }

    @Test("recovery hold degrades auto-fix planning to preview")
    func recoveryHoldBlocksAutomaticWrite() async {
        let records = RunRecordProbe()
        let planID = FixPlanID()
        let capturedAt = Date(timeIntervalSince1970: 100)
        let configuration = FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(),
            capturedAt: capturedAt
        )
        let writeProbe = WriteProbe(result: BatchUpdateResult(
            entries: [writeEntry()],
            failedTrackIDs: [],
            errorDescriptions: []
        ))
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            produceFixPlan: { _, _, _ in
                FixPlanProduction(planID: planID, proposalCount: 1)
            },
            prepareAutomaticWrite: { producedPlanID, planning, _ in
                automaticInput(planID: producedPlanID, planning: planning, capturedAt: capturedAt)
            },
            write: .init(writeFixPlan: { input, _, checkpoint in
                try await checkpointWrite(input, using: checkpoint)
                return try await writeProbe.apply(input: input)
            }),
            now: { capturedAt }
        ))
        await orchestrator.restoreRecoveryHold(id: UUID())

        let result = await orchestrator.submit(.preview(
            trigger: .backgroundSync,
            configuration: configuration,
            mode: .autoFix,
            automation: .scheduled,
            requestedTestArtists: [],
            knownTrackCount: 75
        ))

        #expect(result.lifecycle?.intent == .previewFixes)
        #expect(result.lifecycle?.state == .completed)
        #expect(result.lifecycle?.configuration?.hadRecoveryHold == true)
        #expect(await writeProbe.calls.isEmpty)
        let finished = await records.records.filter { $0.finishedAt != nil }
        #expect(finished.map(\.intent) == [.previewFixes])
    }

    @Test("recovery hold admitted during planning blocks automatic write")
    func newRecoveryHoldBlocksAutomaticWrite() async {
        let planGate = SyncGate()
        let planID = FixPlanID()
        let capturedAt = Date(timeIntervalSince1970: 100)
        let configuration = FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(),
            capturedAt: capturedAt
        )
        let writeProbe = WriteProbe(result: BatchUpdateResult(
            entries: [writeEntry()],
            failedTrackIDs: [],
            errorDescriptions: []
        ))
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: ignoreRunRecord,
            produceFixPlan: { _, _, _ in
                await planGate.waitUntilReleased()
                return FixPlanProduction(planID: planID, proposalCount: 1)
            },
            prepareAutomaticWrite: { producedPlanID, planning, _ in
                automaticInput(planID: producedPlanID, planning: planning, capturedAt: capturedAt)
            },
            write: .init(writeFixPlan: { input, _, checkpoint in
                try await checkpointWrite(input, using: checkpoint)
                return try await writeProbe.apply(input: input)
            }),
            now: { capturedAt }
        ))

        let submission = Task {
            await orchestrator.submit(.preview(
                trigger: .backgroundSync,
                configuration: configuration,
                mode: .autoFix,
                automation: .scheduled,
                requestedTestArtists: [],
                knownTrackCount: 75
            ))
        }
        await planGate.waitUntilEntered()
        await orchestrator.restoreRecoveryHold(id: UUID())
        await planGate.release()
        let result = await submission.value

        #expect(result.lifecycle?.intent == .previewFixes)
        #expect(await writeProbe.calls.isEmpty)
    }

    @Test("recovery hold admitted while building input blocks automatic write")
    func builderRecoveryHoldBlocksAutomaticWrite() async {
        let builderGate = SyncGate()
        let planID = FixPlanID()
        let capturedAt = Date(timeIntervalSince1970: 100)
        let configuration = FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(),
            capturedAt: capturedAt
        )
        let writeProbe = WriteProbe(result: BatchUpdateResult(
            entries: [writeEntry()],
            failedTrackIDs: [],
            errorDescriptions: []
        ))
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: ignoreRunRecord,
            produceFixPlan: { _, _, _ in
                FixPlanProduction(planID: planID, proposalCount: 1)
            },
            prepareAutomaticWrite: { producedPlanID, planning, _ in
                await builderGate.waitUntilReleased()
                return automaticInput(planID: producedPlanID, planning: planning, capturedAt: capturedAt)
            },
            write: .init(writeFixPlan: { input, _, checkpoint in
                try await checkpointWrite(input, using: checkpoint)
                return try await writeProbe.apply(input: input)
            }),
            now: { capturedAt }
        ))

        let submission = Task {
            await orchestrator.submit(.preview(
                trigger: .backgroundSync,
                configuration: configuration,
                mode: .autoFix,
                automation: .scheduled,
                requestedTestArtists: [],
                knownTrackCount: 75
            ))
        }
        await builderGate.waitUntilEntered()
        await orchestrator.restoreRecoveryHold(id: UUID())
        await builderGate.release()
        let result = await submission.value

        #expect(result.lifecycle?.intent == .previewFixes)
        #expect(result.lifecycle?.state == .completed)
        #expect(await writeProbe.calls.isEmpty)
    }

    @Test("recovery hold admitted while persisting planning blocks automatic write")
    func persistenceRecoveryHoldBlocksAutomaticWrite() async {
        let persistenceGate = SyncGate()
        let records = GatedRunRecordProbe(gatedCall: 2, gate: persistenceGate)
        let planID = FixPlanID()
        let capturedAt = Date(timeIntervalSince1970: 100)
        let configuration = FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(),
            capturedAt: capturedAt
        )
        let writeProbe = WriteProbe(result: BatchUpdateResult(
            entries: [writeEntry()],
            failedTrackIDs: [],
            errorDescriptions: []
        ))
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            produceFixPlan: { _, _, _ in
                FixPlanProduction(planID: planID, proposalCount: 1)
            },
            prepareAutomaticWrite: { producedPlanID, planning, _ in
                automaticInput(planID: producedPlanID, planning: planning, capturedAt: capturedAt)
            },
            write: .init(writeFixPlan: { input, _, checkpoint in
                try await checkpointWrite(input, using: checkpoint)
                return try await writeProbe.apply(input: input)
            }),
            now: { capturedAt }
        ))

        let submission = Task {
            await orchestrator.submit(.preview(
                trigger: .backgroundSync,
                configuration: configuration,
                mode: .autoFix,
                automation: .scheduled,
                requestedTestArtists: [],
                knownTrackCount: 75
            ))
        }
        await persistenceGate.waitUntilEntered()
        await orchestrator.restoreRecoveryHold(id: UUID())
        await persistenceGate.release()
        let result = await submission.value

        #expect(result.lifecycle?.intent == .previewFixes)
        #expect(result.lifecycle?.state == .completed)
        #expect(await writeProbe.calls.isEmpty)
    }
}

private enum SupersedingRun: CaseIterable {
    case autoFix
    case batch
}

private struct StalePlanFixture {
    let records: RunRecordProbe
    let planningGate: SyncGate
    let manualPlanID: FixPlanID
    let scheduledConfiguration: FixPlanConfig
    let manualConfiguration: FixPlanConfig
    let writeProbe: WriteProbe
    let orchestrator: RunOrchestrator
}

private enum AdmissionFactoryCase: CaseIterable {
    case automaticBackground
    case automaticWatch
    case automaticManual
    case automaticRecovery
    case manualReviewed
    case manualAutomatic
    case continuationReviewed
    case continuationAutomatic

    var authority: WriteAuthority {
        switch self {
        case .manualReviewed, .continuationReviewed:
            .reviewedPlan
        default:
            .automaticPlan
        }
    }

    var expectedFeature: AppFeature? {
        switch self {
        case .automaticBackground, .automaticWatch, .manualAutomatic, .continuationAutomatic:
            .autoSync
        case .automaticManual, .automaticRecovery, .manualReviewed, .continuationReviewed:
            nil
        }
    }

    func makeRequest(_ input: FixPlanWriteInput) throws -> RunRequest {
        switch self {
        case .automaticBackground:
            .automaticWrite(trigger: .backgroundSync, input: input)
        case .automaticWatch:
            .automaticWrite(trigger: .fileSystemEvent, input: input)
        case .automaticManual:
            .automaticWrite(trigger: .manualCheck, input: input)
        case .automaticRecovery:
            .automaticWrite(trigger: .recovery, input: input)
        case .manualReviewed, .manualAutomatic:
            .manualWrite(input: input)
        case .continuationReviewed, .continuationAutomatic:
            try .continuation(of: continuationSource(for: input), input: input)
        }
    }
}

private enum AutomaticInputMutation: CaseIterable, Equatable {
    case plan
    case scope
    case mode
    case authority
    case automation
    case configurationScope
    case settings
    case recovery

    func applying(to input: FixPlanWriteInput) -> FixPlanWriteInput {
        let target = if self == .plan {
            FixPlanWriteTarget(
                planID: FixPlanID(),
                planRevision: input.target.planRevision,
                decisionRevision: input.target.decisionRevision
            )
        } else {
            input.target
        }
        let scope = if self == .scope {
            ProcessingScopeSnapshot(
                id: UUID(),
                createdAt: input.scope.createdAt,
                source: input.scope.source,
                normalizedTestArtists: input.scope.normalizedTestArtists,
                matchingRule: input.scope.matchingRule,
                knownTrackCount: input.scope.knownTrackCount,
                fingerprint: input.scope.fingerprint,
                reason: input.scope.reason
            )
        } else {
            input.scope
        }
        let configuration = RunConfig(
            id: input.configuration.id,
            capturedAt: input.configuration.capturedAt,
            mode: self == .mode ? .preview : input.configuration.mode,
            writeAuthority: self == .authority ? .reviewedPlan : input.configuration.writeAuthority,
            automation: self == .automation ? .manualOnly : input.configuration.automation,
            scopeID: self == .configurationScope ? UUID() : input.configuration.scopeID,
            settings: self == .settings ? alteredSettings(input.configuration.settings) : input.configuration.settings,
            hadRecoveryHold: self == .recovery
        )
        return FixPlanWriteInput(
            target: target,
            scope: scope,
            admission: input.admission,
            configuration: configuration,
            workItems: input.workItems
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

private func admissionInput(authority: WriteAuthority) -> FixPlanWriteInput {
    let capturedAt = Date(timeIntervalSince1970: 100)
    let planning = RunConfig(
        capturedAt: capturedAt,
        mode: .autoFix,
        writeAuthority: .readOnly,
        automation: .hybrid,
        scopeID: UUID(),
        settings: planConfiguration(capturedAt: capturedAt),
        hadRecoveryHold: false
    )
    let input = automaticInput(
        planID: FixPlanID(),
        planning: planning,
        capturedAt: capturedAt
    )
    return FixPlanWriteInput(
        target: input.target,
        scope: input.scope,
        admission: input.admission,
        configuration: RunConfig(
            capturedAt: capturedAt,
            mode: .autoFix,
            writeAuthority: authority,
            automation: planning.automation,
            scopeID: input.scope.id,
            settings: planning.settings,
            hadRecoveryHold: false
        ),
        workItems: input.workItems
    )
}

private func continuationSource(for input: FixPlanWriteInput) -> RunRecord {
    let startedAt = Date(timeIntervalSince1970: 100)
    return makeRunRecord(
        startedAt: startedAt,
        finishedAt: startedAt.addingTimeInterval(10),
        state: .cancelled,
        syncSummary: nil,
        input: RunRecordInput(
            intent: .writeFixes,
            writeTarget: input.target,
            workItems: [makeWorkItem(state: .outcome(.failed))],
            includesSyncTransition: false
        )
    )
}

private func ignoreRunRecord(_ record: RunRecord) async throws {
    _ = record
}

private func planConfiguration(
    capturedAt: Date,
    options: UpdateOptions = UpdateOptions()
) -> FixPlanConfig {
    FixPlanConfig.capture(
        configuration: AppConfiguration(),
        options: options,
        capturedAt: capturedAt
    )
}

private func stalePlanFixture() -> StalePlanFixture {
    let records = RunRecordProbe()
    let planningGate = SyncGate()
    let scheduledPlanID = FixPlanID()
    let manualPlanID = FixPlanID()
    let capturedAt = Date(timeIntervalSince1970: 100)
    let scheduledConfiguration = planConfiguration(capturedAt: capturedAt)
    let manualConfiguration = planConfiguration(
        capturedAt: capturedAt,
        options: UpdateOptions(minConfidence: 80)
    )
    let writeProbe = WriteProbe(result: BatchUpdateResult(
        entries: [writeEntry()],
        failedTrackIDs: [],
        errorDescriptions: []
    ))
    let orchestrator = RunOrchestrator(dependencies: .init(
        synchronizeLibrary: { SyncResult() },
        persistRunRecord: { try await records.append($0) },
        produceFixPlan: { _, _, configuration in
            if configuration.id == scheduledConfiguration.id {
                await planningGate.waitUntilReleased()
                return FixPlanProduction(planID: scheduledPlanID, proposalCount: 1)
            }
            return FixPlanProduction(planID: manualPlanID, proposalCount: 1)
        },
        prepareAutomaticWrite: { producedPlanID, planning, _ in
            automaticInput(planID: producedPlanID, planning: planning, capturedAt: capturedAt)
        },
        write: .init(writeFixPlan: { input, _, checkpoint in
            try await checkpointWrite(input, using: checkpoint)
            return try await writeProbe.apply(input: input)
        }),
        runBatchUpdate: { _, _ in
            BatchUpdateResult(entries: [], failedTrackIDs: [], errorDescriptions: [])
        },
        now: { capturedAt }
    ))
    return StalePlanFixture(
        records: records,
        planningGate: planningGate,
        manualPlanID: manualPlanID,
        scheduledConfiguration: scheduledConfiguration,
        manualConfiguration: manualConfiguration,
        writeProbe: writeProbe,
        orchestrator: orchestrator
    )
}

extension RunSubmissionResult {
    fileprivate var isQueued: Bool {
        if case .queued = self {
            true
        } else {
            false
        }
    }
}
