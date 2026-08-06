import Foundation
import SwiftData
import Testing
@testable import Services

@Suite("Recovery resolution lookup")
struct RecoveryLookupTests {
    private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("a resolved claim is found through the recovery column")
    func resolvesClaimViaRecoveryColumn() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let claimID = UUID()
        let resolved = terminalRecoveryRecord(at: 0, recoveryID: claimID)
        try await store.upsert(resolved)
        try await store.upsert(terminalRecoveryRecord(at: 1, recoveryID: UUID()))

        let runID = try await store.resolvedRecoveryRun(recoveryID: claimID)

        #expect(runID == resolved.runID)
    }

    @Test("a legacy row without the column resolves through the payload fallback")
    func resolvesLegacyRowViaPayloadFallback() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let claimID = UUID()
        let resolved = terminalRecoveryRecord(at: 0, recoveryID: claimID)
        try await store.upsert(resolved)

        let context = ModelContext(container)
        let row = try #require(context.fetch(FetchDescriptor<PersistedRunRecord>()).first)
        row.recoveryID = nil
        try context.save()

        let runID = try await store.resolvedRecoveryRun(recoveryID: claimID)

        #expect(runID == resolved.runID)
    }

    @Test("an open claim is not a resolution")
    func openClaimIsNotResolved() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let claimID = UUID()
        let open = makeRunRecord(
            startedAt: baseDate,
            finishedAt: nil,
            state: .recoverable,
            syncSummary: nil,
            input: RunRecordInput(
                intent: .writeFixes,
                writeTarget: writeTarget(),
                recoveryID: claimID,
                workItems: [makeWorkItem(state: .attempted)],
                includesSyncTransition: false
            )
        )
        try await store.upsert(open)

        let runID = try await store.resolvedRecoveryRun(recoveryID: claimID)

        #expect(runID == nil)
    }

    @Test("the newest decodable claim carrier wins")
    func newestDecodableCarrierWins() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let claimID = UUID()
        let older = terminalRecoveryRecord(at: 0, recoveryID: claimID)
        let newer = terminalRecoveryRecord(at: 1, recoveryID: claimID)
        try await store.upsert(older)
        try await store.upsert(newer)

        let runID = try await store.resolvedRecoveryRun(recoveryID: claimID)

        #expect(runID == newer.runID)
    }

    @Test("a corrupted claim carrier never resolves the claim")
    func corruptedCarrierDoesNotResolve() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let claimID = UUID()
        try await store.upsert(terminalRecoveryRecord(at: 0, recoveryID: claimID))

        let context = ModelContext(container)
        let row = try #require(context.fetch(FetchDescriptor<PersistedRunRecord>()).first)
        row.scopeData = Data("garbage".utf8)
        try context.save()

        // The replaced full-history scan never let an undecodable row resolve
        // a claim; the column arm must keep that filter.
        let runID = try await store.resolvedRecoveryRun(recoveryID: claimID)

        #expect(runID == nil)
    }

    @Test("a newer legacy carrier beats an older column carrier")
    func legacyNewerCarrierBeatsColumnOlder() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = RunRecordDataStore(modelContainer: container)
        let claimID = UUID()
        let older = terminalRecoveryRecord(at: 0, recoveryID: claimID)
        let newer = terminalRecoveryRecord(at: 1, recoveryID: claimID)
        try await store.upsert(older)
        try await store.upsert(newer)

        let context = ModelContext(container)
        let newerRunID = newer.runID.rawValue
        let newerRow = try #require(context.fetch(FetchDescriptor<PersistedRunRecord>(
            predicate: #Predicate { $0.runID == newerRunID }
        )).first)
        newerRow.recoveryID = nil
        try context.save()

        let runID = try await store.resolvedRecoveryRun(recoveryID: claimID)

        #expect(runID == newer.runID)
    }

    @Test("an unknown claim resolves to nil")
    func unknownClaimResolvesNil() async throws {
        let store = try RunRecordDataStore(modelContainer: ModelContainerFactory.createInMemory())

        let runID = try await store.resolvedRecoveryRun(recoveryID: UUID())

        #expect(runID == nil)
    }

    private func terminalRecoveryRecord(at index: Int, recoveryID: UUID) -> RunRecord {
        let startedAt = baseDate.addingTimeInterval(Double(index) * 10)
        return makeRunRecord(
            startedAt: startedAt,
            finishedAt: startedAt.addingTimeInterval(5),
            state: .cancelled,
            syncSummary: nil,
            input: RunRecordInput(
                intent: .writeFixes,
                writeTarget: writeTarget(),
                recoveryID: recoveryID,
                workItems: [makeWorkItem(state: .outcome(.written))],
                includesSyncTransition: false
            )
        )
    }
}
