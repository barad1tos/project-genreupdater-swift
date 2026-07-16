import Core
import Foundation
import SwiftData
import Testing
@testable import Services

func validRunTransitionsData() throws -> Data {
    try JSONEncoder().encode([
        RunLifecycleTransition(state: .created, timestamp: Date(timeIntervalSince1970: 100)),
        RunLifecycleTransition(state: .syncingLibrary, timestamp: Date(timeIntervalSince1970: 101)),
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

func insertRunRow(
    runID: UUID,
    transitionsData: Data,
    scopeData: Data? = nil,
    intent: RunIntent = .observeLibrary,
    rawIntent: String? = nil,
    state: RunLifecycleState = .completed,
    startedAt: Date = Date(timeIntervalSince1970: 100),
    finishedAt: Date? = nil,
    into container: ModelContainer
) throws {
    let context = ModelContext(container)
    let scopeData = try scopeData ?? JSONEncoder().encode(ProcessingScopeSnapshot.capture(
        requestedTestArtists: [],
        knownTrackCount: 1,
        createdAt: Date(timeIntervalSince1970: 100),
        reason: "manualCheck"
    ))
    context.insert(PersistedRunRecord(
        runID: runID,
        requestID: UUID(),
        triggerRaw: RunTrigger.manualCheck.rawValue,
        intentRaw: rawIntent ?? intent.rawValue,
        stateRaw: state.rawValue,
        scopeData: scopeData,
        transitionsData: transitionsData,
        syncNewCount: nil,
        syncModifiedCount: nil,
        syncIdentityChangedCount: nil,
        syncRefreshedCount: nil,
        syncRemovedCount: nil,
        failureMessage: nil,
        startedAt: startedAt,
        finishedAt: finishedAt
    ))
    try context.save()
}

func makeRunStore() throws -> RunRecordDataStore {
    let container = try ModelContainerFactory.createInMemory()
    return RunRecordDataStore(modelContainer: container)
}

func makeRunRecord(
    runID: RunID = RunID(),
    requestID: RunRequestID = RunRequestID(),
    trigger: RunTrigger = .manualCheck,
    intent: RunIntent = .observeLibrary,
    writeTarget: FixPlanWriteTarget? = nil,
    recoveryID: UUID? = nil,
    startedAt: Date,
    finishedAt: Date?,
    state: RunLifecycleState,
    syncSummary: ActivitySyncSummary?,
    writeSummary: RunWriteSummary? = nil,
    configurationScopeID: UUID? = nil,
    scope: ProcessingScopeSnapshot? = nil,
    configuration: RunConfig? = nil,
    includesSyncTransition: Bool = true
) -> RunRecord {
    var transitions = [RunLifecycleTransition(state: .created, timestamp: startedAt)]
    if includesSyncTransition {
        transitions.append(RunLifecycleTransition(
            state: .syncingLibrary,
            timestamp: startedAt.addingTimeInterval(1)
        ))
    }
    let initialState: RunLifecycleState = includesSyncTransition ? .syncingLibrary : .created
    if state != initialState {
        transitions.append(RunLifecycleTransition(
            state: state,
            timestamp: finishedAt ?? startedAt.addingTimeInterval(2)
        ))
    }

    let scope = scope ?? ProcessingScopeSnapshot.capture(
        requestedTestArtists: ["Aphex Twin"],
        knownTrackCount: 75,
        createdAt: startedAt,
        reason: "manualCheck"
    )
    let authority: WriteAuthority = intent == .writeFixes ? .reviewedPlan : .readOnly

    return RunRecord(
        runID: runID,
        requestID: requestID,
        trigger: trigger,
        intent: intent,
        scope: scope,
        configuration: configuration ?? makeRunConfiguration(
            scopeID: configurationScopeID ?? scope.id,
            capturedAt: startedAt,
            writeAuthority: authority
        ),
        writeTarget: writeTarget,
        recoveryID: recoveryID,
        transitions: transitions,
        syncSummary: syncSummary,
        writeSummary: writeSummary,
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
        intent: intent,
        writeTarget: writeTarget,
        recoveryID: recoveryID,
        startedAt: startedAt,
        finishedAt: finishedAt,
        state: state,
        syncSummary: nil,
        writeSummary: writeSummary,
        includesSyncTransition: false
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
