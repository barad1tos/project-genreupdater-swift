import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Recovery restore")
@MainActor
struct RecoveryRestoreTests {
    @Test(
        "Interrupted writes restore a durable hold",
        arguments: [
            RunLifecycleState.writing,
            .verifying,
            .reporting,
            .blocked,
            .recoverable,
            .recovering,
        ]
    )
    func restoresInterruptedWrite(state: RunLifecycleState) async throws {
        let setup = try makeRecoverySetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let record = sampleRunRecord(
            intent: .writeFixes,
            state: state,
            failureMessage: "Write interrupted",
            finishedAt: nil
        )
        try await setup.store.upsert(record)

        #expect(await setup.dependencies.ensureRecoveryHold())

        let recoveryID = try #require(await setup.processor.recoveryHoldID())
        let restored = try #require(await setup.store.record(for: record.runID))
        #expect(restored.state == (state == .blocked ? .blocked : .recoverable))
        #expect(restored.recoveryID == recoveryID)
        #expect(restored.failureMessage == "Write interrupted")
    }

    @Test("Corrupted interrupted write restores a fail-closed hold")
    func restoresCorruptedWrite() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let setup = try makeRecoverySetup(store: store)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let runID = UUID()
        try insertCorruptedRun(id: runID, state: .recoverable, into: container)

        #expect(await setup.dependencies.ensureRecoveryHold())

        #expect(await setup.processor.recoveryHoldID() == runID)
    }

    @Test("Opaque read-only runs restore a fail-closed hold")
    func holdsOpaqueReadOnly() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let setup = try makeRecoverySetup(store: store)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let runID = UUID()
        try insertCorruptedRun(
            id: runID,
            state: .reporting,
            intentRaw: RunIntent.observeLibrary.rawValue,
            into: container
        )

        #expect(await setup.dependencies.ensureRecoveryHold())

        #expect(await setup.processor.recoveryHoldID() == runID)
        let page = try await store.reports(matching: RunReportQuery())
        #expect(page.records.isEmpty)
        #expect(page.attentionRunIDs == [RunID(rawValue: runID)])
    }

    @Test("Conflicting write evidence restores a fail-closed hold")
    func holdsConflictingWrite() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let setup = try makeRecoverySetup(store: store)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let configuration = RunConfig(
            capturedAt: startedAt,
            writeAuthority: .reviewedPlan,
            automation: .manualOnly,
            scopeID: UUID(),
            settings: FixPlanConfig.capture(
                configuration: AppConfiguration(),
                options: UpdateOptions(),
                capturedAt: startedAt
            ),
            hadRecoveryHold: false
        )
        let payload = ConflictingRecoveryPayload(
            transitions: [
                RunLifecycleTransition(state: .created, timestamp: startedAt),
                RunLifecycleTransition(state: .reporting, timestamp: startedAt.addingTimeInterval(1)),
            ],
            configuration: configuration
        )
        try insertCorruptedRun(
            id: runID,
            state: .reporting,
            intentRaw: RunIntent.observeLibrary.rawValue,
            transitionsData: JSONEncoder().encode(payload),
            into: container
        )

        #expect(await setup.dependencies.ensureRecoveryHold())

        #expect(await setup.processor.recoveryHoldID() == runID)
    }

    @Test("Opaque blocked read-only corruption cannot be dismissed")
    func holdsBlockedReadOnly() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let setup = try makeRecoverySetup(store: store)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let runID = UUID()
        try insertCorruptedRun(
            id: runID,
            state: .blocked,
            intentRaw: RunIntent.observeLibrary.rawValue,
            into: container
        )
        #expect(await setup.dependencies.ensureRecoveryHold())

        await #expect(throws: AppDependencyServiceError.recoveryBlocked) {
            try await setup.dependencies.clearRecoveryHold(id: runID)
        }

        #expect(await setup.processor.recoveryHoldID() == runID)
        let page = try await store.reports(matching: RunReportQuery())
        #expect(page.records.isEmpty)
        #expect(page.attentionRunIDs == [RunID(rawValue: runID)])
    }

    @Test("Store failures create a fail-closed batch hold")
    func storeFailureHolds() async throws {
        let setup = try makeRecoverySetup(
            store: RunRecordStoreStub(reportsError: CocoaError(.fileReadCorruptFile))
        )
        defer { try? FileManager.default.removeItem(at: setup.directory) }

        #expect(await setup.dependencies.ensureRecoveryHold())

        #expect(await setup.processor.recoveryHoldID() != nil)
    }

    @Test("Recovery claim failures create a fail-closed batch hold")
    func claimFailureHolds() async throws {
        let record = sampleRunRecord(
            intent: .writeFixes,
            state: .writing,
            finishedAt: nil
        )
        let setup = try makeRecoverySetup(store: RunRecordStoreStub(
            claimError: CocoaError(.fileWriteUnknown),
            storedRecord: record,
            reportPage: RunReportPage(records: [record], skippedCorruptedCount: 0)
        ))
        defer { try? FileManager.default.removeItem(at: setup.directory) }

        #expect(await setup.dependencies.ensureRecoveryHold())

        #expect(await setup.processor.recoveryHoldID() != nil)
    }
}

private struct ConflictingRecoveryPayload: Encodable {
    let version = 2
    let transitions: [RunLifecycleTransition]
    let configuration: RunConfig
    let writeSummary = "invalid"
}
