import Core
import Foundation
import SwiftData
import Testing
@testable import Services

func validRunTransitionsData() throws -> Data {
    try JSONEncoder().encode([
        RunLifecycleTransition(state: .created, timestamp: Date(timeIntervalSince1970: 100)),
        RunLifecycleTransition(state: .syncingLibrary, timestamp: Date(timeIntervalSince1970: 101))
    ])
}

func assertCorruptedRunField(
    store: RunRecordDataStore,
    expectedName: String,
    expectedRunID: UUID
) async {
    do {
        _ = try await store.loadAll()
        Issue.record("Expected loadAll to throw RunRecordPersistenceError.corruptedField")
    } catch let error as RunRecordPersistenceError {
        guard case let .corruptedField(name, runID) = error else {
            Issue.record("Expected corruptedField, got \(error)")
            return
        }
        #expect(name == expectedName)
        #expect(runID == expectedRunID)
    } catch {
        Issue.record("Expected RunRecordPersistenceError, got \(error)")
    }
}

struct RunRowInput {
    var scopeData: Data?
    var intent: RunIntent = .observeLibrary
    var rawIntent: String?
    var state: RunLifecycleState = .completed
    var startedAt = Date(timeIntervalSince1970: 100)
    var finishedAt: Date?
}

func insertRunRow(
    runID: UUID,
    transitionsData: Data,
    input: RunRowInput = RunRowInput(),
    into container: ModelContainer
) throws {
    let context = ModelContext(container)
    let scopeData = try input.scopeData ?? JSONEncoder().encode(ProcessingScopeSnapshot.capture(
        requestedTestArtists: [],
        knownTrackCount: 1,
        createdAt: Date(timeIntervalSince1970: 100),
        reason: "manualCheck"
    ))
    context.insert(PersistedRunRecord(
        runID: runID,
        requestID: UUID(),
        triggerRaw: RunTrigger.manualCheck.rawValue,
        intentRaw: input.rawIntent ?? input.intent.rawValue,
        stateRaw: input.state.rawValue,
        scopeData: scopeData,
        transitionsData: transitionsData,
        syncNewCount: nil,
        syncModifiedCount: nil,
        syncIdentityChangedCount: nil,
        syncRefreshedCount: nil,
        syncRemovedCount: nil,
        failureMessage: nil,
        startedAt: input.startedAt,
        finishedAt: input.finishedAt
    ))
    try context.save()
}

func makeRunStore() throws -> RunRecordDataStore {
    let container = try ModelContainerFactory.createInMemory()
    return RunRecordDataStore(modelContainer: container)
}

struct RunRecordInput {
    var runID = RunID()
    var requestID = RunRequestID()
    var trigger: RunTrigger = .manualCheck
    var intent: RunIntent = .observeLibrary
    var writeTarget: FixPlanWriteTarget?
    var recoveryID: UUID?
    var writeSummary: RunWriteSummary?
    var workItems: [RunWorkItem] = []
    var configurationScopeID: UUID?
    var scope: ProcessingScopeSnapshot?
    var configuration: RunConfig?
    var includesSyncTransition = true
}

func makeRunRecord(
    startedAt: Date,
    finishedAt: Date?,
    state: RunLifecycleState,
    syncSummary: ActivitySyncSummary?,
    input: RunRecordInput = RunRecordInput()
) -> RunRecord {
    var transitions = [RunLifecycleTransition(state: .created, timestamp: startedAt)]
    if input.includesSyncTransition {
        transitions.append(RunLifecycleTransition(
            state: .syncingLibrary,
            timestamp: startedAt.addingTimeInterval(1)
        ))
    }
    let initialState: RunLifecycleState = input.includesSyncTransition ? .syncingLibrary : .created
    if state != initialState {
        transitions.append(RunLifecycleTransition(
            state: state,
            timestamp: finishedAt ?? startedAt.addingTimeInterval(2)
        ))
    }

    let scope = input.scope ?? ProcessingScopeSnapshot.capture(
        requestedTestArtists: ["Aphex Twin"],
        knownTrackCount: 75,
        createdAt: startedAt,
        reason: "manualCheck"
    )
    let authority: WriteAuthority = input.intent == .writeFixes ? .reviewedPlan : .readOnly

    return RunRecord(
        runID: input.runID,
        requestID: input.requestID,
        trigger: input.trigger,
        intent: input.intent,
        scope: scope,
        configuration: input.configuration ?? makeRunConfiguration(
            scopeID: input.configurationScopeID ?? scope.id,
            capturedAt: startedAt,
            writeAuthority: authority
        ),
        writeTarget: input.writeTarget,
        recoveryID: input.recoveryID,
        transitions: transitions,
        workItems: input.workItems,
        syncSummary: syncSummary,
        writeSummary: input.writeSummary,
        failureMessage: state == .failed ? "Music.app unavailable" : nil,
        startedAt: startedAt,
        finishedAt: finishedAt
    )
}

func replacing(
    _ record: RunRecord,
    scope: ProcessingScopeSnapshot,
    configuration: RunConfig?
) -> RunRecord {
    RunRecord(
        runID: record.runID,
        requestID: record.requestID,
        trigger: record.trigger,
        intent: record.intent,
        scope: scope,
        configuration: configuration,
        writeTarget: record.writeTarget,
        recoveryID: record.recoveryID,
        transitions: record.transitions,
        syncSummary: record.syncSummary,
        writeSummary: record.writeSummary,
        failureMessage: record.failureMessage,
        startedAt: record.startedAt,
        finishedAt: record.finishedAt
    )
}

func makeRunConfiguration(
    scopeID: UUID,
    capturedAt: Date,
    writeAuthority: WriteAuthority = .readOnly,
    automation: AutomationStrategy = .manualOnly,
    appConfiguration: AppConfiguration = AppConfiguration(),
    options: UpdateOptions = UpdateOptions()
) -> RunConfig {
    RunConfig(
        capturedAt: capturedAt,
        writeAuthority: writeAuthority,
        automation: automation,
        scopeID: scopeID,
        settings: FixPlanConfig.capture(
            configuration: appConfiguration,
            options: options,
            capturedAt: capturedAt
        ),
        hadRecoveryHold: false
    )
}

func makeRecoveryRecord(
    intent: RunIntent = .observeLibrary,
    writeTarget: FixPlanWriteTarget? = nil,
    recoveryID: UUID? = nil,
    startedAt: Date,
    finishedAt: Date?,
    state: RunLifecycleState,
    writeSummary: RunWriteSummary? = nil
) -> RunRecord {
    makeRunRecord(
        startedAt: startedAt,
        finishedAt: finishedAt,
        state: state,
        syncSummary: nil,
        input: RunRecordInput(
            intent: intent,
            writeTarget: writeTarget,
            recoveryID: recoveryID,
            writeSummary: writeSummary,
            includesSyncTransition: false
        )
    )
}

struct LegacyPayload: Encodable {
    let version = 1
    let transitions: [RunLifecycleTransition]
}

struct CorruptedConfigPayload: Encodable {
    let version = 2
    let transitions: [RunLifecycleTransition]
    let configuration = "invalid"
    let writeTarget: FixPlanWriteTarget
    let recoveryID: UUID
    let writeSummary: RunWriteSummary
}

struct MissingConfigPayload: Encodable {
    let version = 2
    let transitions: [RunLifecycleTransition]
}

struct MissingVersionPayload: Encodable {
    let transitions: [RunLifecycleTransition]
}

struct WrongVersionPayload: Encodable {
    let version = "2"
    let transitions: [RunLifecycleTransition]
}

struct InvalidVersionPayload: Encodable {
    let version: Int
    let transitions: [RunLifecycleTransition]
}

struct LegacyConfigPayload: Encodable {
    let version = 1
    let transitions: [RunLifecycleTransition]
    let configuration: RunConfig
}

struct CorruptedSummaryPayload: Encodable {
    let version = 2
    let transitions: [RunLifecycleTransition]
    let configuration: RunConfig
    let writeSummary = "invalid"
}

struct MalformedWriteTargetPayload: Encodable {
    let version = 2
    let transitions: [RunLifecycleTransition]
    let configuration: RunConfig
    let writeTarget = "invalid"
}

struct VersionedPayload: Encodable {
    let version = 2
    let transitions: [RunLifecycleTransition]
    let configuration: RunConfig
}
