import Foundation
import SwiftData
import Testing
@testable import Services

@Suite("Run record corruption persistence")
struct RunCorruptionTests {
    @Test("Corrupt recovery artifacts cannot hide a blocked transition")
    func preservesBlockedTransition() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        let payload = VersionedPayload(
            transitions: [
                RunLifecycleTransition(state: .created, timestamp: startedAt),
                RunLifecycleTransition(state: .blocked, timestamp: startedAt.addingTimeInterval(1)),
                RunLifecycleTransition(state: .writing, timestamp: startedAt.addingTimeInterval(2)),
            ],
            configuration: makeRunConfiguration(scopeID: scope.id, capturedAt: startedAt)
        )
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(payload),
            input: RunRowInput(
                scopeData: JSONEncoder().encode(scope),
                intent: .writeFixes,
                state: .writing
            ),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        #expect(try await store.closeCorruptedRun(RunID(rawValue: runID), at: Date()) == false)
        let page = try await store.recoveryRecords()
        #expect(page.recoveryRunIDs.isEmpty)
        #expect(page.attentionRunIDs == [RunID(rawValue: runID)])
        #expect(try await store.closeReadOnlyCorruption(RunID(rawValue: runID), at: Date()) == false)
    }

    @Test("Finished header cannot hide interrupted write evidence")
    func keepsFinishedWrite() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(CorruptedSummaryPayload(
                transitions: [
                    RunLifecycleTransition(state: .created, timestamp: startedAt),
                    RunLifecycleTransition(state: .writing, timestamp: startedAt.addingTimeInterval(1)),
                ],
                configuration: makeRunConfiguration(scopeID: scope.id, capturedAt: startedAt)
            )),
            input: RunRowInput(
                scopeData: JSONEncoder().encode(scope),
                intent: .writeFixes,
                state: .writing,
                finishedAt: startedAt.addingTimeInterval(2)
            ),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)
        try await store.upsert(makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 200),
            finishedAt: Date(timeIntervalSince1970: 201),
            state: .completed,
            syncSummary: nil
        ))

        #expect(try await store.prune(keepingLatest: 1) == 0)
        let page = try await store.recoveryRecords()
        #expect(page.recoveryRunIDs == [RunID(rawValue: runID)])
        #expect(try await store.closeCorruptedRun(
            RunID(rawValue: runID),
            at: Date(timeIntervalSince1970: 300)
        ))
    }

    @Test("Prune preserves opaque terminal corruption")
    func preservesOpaqueCorruption() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        try insertRunRow(
            runID: runID,
            transitionsData: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            input: RunRowInput(
                state: .cancelled,
                startedAt: Date(timeIntervalSince1970: 100),
                finishedAt: Date(timeIntervalSince1970: 101)
            ),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)
        try await store.upsert(makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 200),
            finishedAt: Date(timeIntervalSince1970: 201),
            state: .completed,
            syncSummary: nil
        ))

        #expect(try await store.prune(keepingLatest: 1) == 0)
        await #expect(throws: RunRecordPersistenceError.self) {
            try await store.record(for: RunID(rawValue: runID))
        }
    }

    @Test("Prune preserves terminal future payloads")
    func preservesFuturePayload() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(FutureRunPayload()),
            input: RunRowInput(
                state: .cancelled,
                startedAt: Date(timeIntervalSince1970: 100),
                finishedAt: Date(timeIntervalSince1970: 101)
            ),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)
        try await store.upsert(makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 200),
            finishedAt: Date(timeIntervalSince1970: 201),
            state: .completed,
            syncSummary: nil
        ))

        #expect(try await store.prune(keepingLatest: 1) == 0)
        let page = try await store.reports(matching: RunReportQuery())
        #expect(page.unsupportedRunIDs == [RunID(rawValue: runID)])
        let rows = try ModelContext(container).fetch(FetchDescriptor<PersistedRunRecord>())
        #expect(rows.contains { $0.runID == runID })
    }

    @Test("Recovery never appends after a terminal transition")
    func holdsTerminalPayload() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(VersionedPayload(
                transitions: [
                    RunLifecycleTransition(state: .created, timestamp: startedAt),
                    RunLifecycleTransition(state: .completed, timestamp: startedAt.addingTimeInterval(1)),
                ],
                configuration: makeRunConfiguration(scopeID: scope.id, capturedAt: startedAt)
            )),
            input: RunRowInput(
                scopeData: JSONEncoder().encode(scope),
                intent: .writeFixes,
                state: .recoverable
            ),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        let page = try await store.recoveryRecords()

        #expect(page.attentionRunIDs == [RunID(rawValue: runID)])
        #expect(try await store.closeCorruptedRun(RunID(rawValue: runID), at: Date()) == false)
        #expect(try await store.closeReadOnlyCorruption(RunID(rawValue: runID), at: Date()) == false)
    }

    @Test("Blocked read-only corruption preserves write evidence")
    func holdsBlockedWriteEvidence() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(VersionedPayload(
                transitions: [
                    RunLifecycleTransition(state: .created, timestamp: startedAt),
                    RunLifecycleTransition(state: .blocked, timestamp: startedAt.addingTimeInterval(1)),
                ],
                configuration: makeRunConfiguration(
                    scopeID: scope.id,
                    capturedAt: startedAt,
                    writeAuthority: .reviewedPlan
                )
            )),
            input: RunRowInput(
                scopeData: JSONEncoder().encode(scope),
                intent: .observeLibrary,
                state: .blocked
            ),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        let page = try await store.recoveryRecords()

        #expect(page.attentionRunIDs == [RunID(rawValue: runID)])
        #expect(try await store.closeReadOnlyCorruption(RunID(rawValue: runID), at: Date()) == false)
    }

    @Test("Blocked read-only corruption requires attention")
    func holdsBlockedReadOnly() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let configuration = makeRunConfiguration(scopeID: UUID(), capturedAt: startedAt)
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(VersionedPayload(
                transitions: [
                    RunLifecycleTransition(state: .created, timestamp: startedAt),
                    RunLifecycleTransition(state: .syncingLibrary, timestamp: startedAt.addingTimeInterval(50)),
                ],
                configuration: configuration
            )),
            input: RunRowInput(
                scopeData: Data([0xDE, 0xAD, 0xBE, 0xEF]),
                intent: .observeLibrary,
                state: .blocked
            ),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        let page = try await store.recoveryRecords()

        #expect(page.attentionRunIDs == [RunID(rawValue: runID)])
        let auditTime = startedAt.addingTimeInterval(25)
        #expect(try await store.closeReadOnlyCorruption(RunID(rawValue: runID), at: auditTime))
        let audit = try #require(await store.record(for: RunID(rawValue: runID)))
        #expect(audit.transitions.map(\.state) == [.created, .syncingLibrary, .blocked, .cancelled])
        #expect(audit.transitions.map(\.timestamp) == audit.transitions.map(\.timestamp).sorted())
        #expect(audit.transitions.last?.timestamp == startedAt.addingTimeInterval(50))
        #expect(audit.finishedAt == startedAt.addingTimeInterval(50))
    }

    @Test("Invalid blocked history cannot be dismissed")
    func holdsInvalidBlockedTail() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(VersionedPayload(
                transitions: [
                    RunLifecycleTransition(state: .created, timestamp: startedAt),
                    RunLifecycleTransition(state: .blocked, timestamp: startedAt.addingTimeInterval(1)),
                    RunLifecycleTransition(state: .reporting, timestamp: startedAt.addingTimeInterval(2)),
                ],
                configuration: makeRunConfiguration(scopeID: scope.id, capturedAt: startedAt)
            )),
            input: RunRowInput(
                scopeData: JSONEncoder().encode(scope),
                intent: .observeLibrary,
                state: .reporting
            ),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        let page = try await store.recoveryRecords()

        #expect(page.attentionRunIDs == [RunID(rawValue: runID)])
        #expect(try await store.closeReadOnlyCorruption(RunID(rawValue: runID), at: Date()) == false)
    }

    @Test("Terminal header without finish requires an explicit close")
    func closesUnfinishedHeader() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(VersionedPayload(
                transitions: [RunLifecycleTransition(state: .created, timestamp: startedAt)],
                configuration: makeRunConfiguration(scopeID: scope.id, capturedAt: startedAt)
            )),
            input: RunRowInput(
                scopeData: JSONEncoder().encode(scope),
                intent: .observeLibrary,
                state: .completed
            ),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        let page = try await store.recoveryRecords()

        #expect(page.attentionRunIDs.isEmpty)
        #expect(page.closableRunIDs == [RunID(rawValue: runID)])
        #expect(try await store.closeReadOnlyCorruption(
            RunID(rawValue: runID),
            at: startedAt.addingTimeInterval(1)
        ))
        let audit = try #require(await store.record(for: RunID(rawValue: runID)))
        #expect(audit.transitions.map(\.state) == [.created, .cancelled])
    }

    @Test("Terminal write header without finish requires write recovery")
    func recoversUnfinishedWriteHeader() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(VersionedPayload(
                transitions: [RunLifecycleTransition(state: .created, timestamp: startedAt)],
                configuration: makeRunConfiguration(
                    scopeID: scope.id,
                    capturedAt: startedAt,
                    writeAuthority: .reviewedPlan
                )
            )),
            input: RunRowInput(
                scopeData: JSONEncoder().encode(scope),
                intent: .writeFixes,
                state: .completed
            ),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        let page = try await store.recoveryRecords()

        #expect(page.recoveryRunIDs == [RunID(rawValue: runID)])
        #expect(try await store.closeCorruptedRun(
            RunID(rawValue: runID),
            at: startedAt.addingTimeInterval(1)
        ))
        let audit = try #require(await store.record(for: RunID(rawValue: runID)))
        #expect(audit.transitions.map(\.state) == [.created, .recovering, .cancelled])
    }

    @Test("Explicit close repairs reversed transition timestamps")
    func repairsReversedTimestamps() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(VersionedPayload(
                transitions: [
                    RunLifecycleTransition(state: .created, timestamp: startedAt.addingTimeInterval(20)),
                    RunLifecycleTransition(state: .syncingLibrary, timestamp: startedAt.addingTimeInterval(10)),
                ],
                configuration: makeRunConfiguration(scopeID: scope.id, capturedAt: startedAt)
            )),
            input: RunRowInput(
                scopeData: JSONEncoder().encode(scope),
                state: .syncingLibrary,
                startedAt: startedAt
            ),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        let page = try await store.recoveryRecords()

        #expect(page.closableRunIDs == [RunID(rawValue: runID)])
        #expect(try await store.closeReadOnlyCorruption(
            RunID(rawValue: runID),
            at: startedAt.addingTimeInterval(15)
        ))
        let audit = try #require(await store.record(for: RunID(rawValue: runID)))
        #expect(audit.transitions.map(\.state) == [.created, .syncingLibrary, .cancelled])
        #expect(audit.transitions.map(\.timestamp) == audit.transitions.map(\.timestamp).sorted())
    }

    @Test("Run configuration scope must match the persisted scope")
    func rejectsMismatchedScope() async throws {
        let store = try makeRunStore()
        let record = makeRunRecord(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 101),
            state: .completed,
            syncSummary: nil,
            input: RunRecordInput(configurationScopeID: UUID())
        )

        do {
            try await store.upsert(record)
            Issue.record("Expected mismatched configuration scope to fail before persistence")
        } catch let RunRecordPersistenceError.invalidField(name, errorRunID) {
            #expect(name == "configuration.scopeID")
            #expect(errorRunID == record.runID.rawValue)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(try await store.loadAll().isEmpty)
    }

    @Test("Invalid v2 configuration holds an open write for safe closure")
    func holdsCorruptWrite() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let target = FixPlanWriteTarget(
            planID: FixPlanID(),
            planRevision: .initial,
            decisionRevision: .initial
        )
        let summary = RunWriteSummary(applied: 1, verifiedNoOp: 0, failed: 0)
        let transitions = [
            RunLifecycleTransition(state: .created, timestamp: Date(timeIntervalSince1970: 100)),
            RunLifecycleTransition(state: .recoverable, timestamp: Date(timeIntervalSince1970: 101)),
        ]
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(CorruptedConfigPayload(
                transitions: transitions,
                writeTarget: target,
                recoveryID: runID,
                writeSummary: summary
            )),
            input: RunRowInput(intent: .writeFixes, state: .recoverable),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        let recoveryPage = try await store.recoveryRecords()
        await #expect(throws: RunRecordPersistenceError.self) {
            _ = try await store.claimRecovery(for: RunID(rawValue: runID), id: UUID(), at: Date())
        }
        let didClose = try await store.closeCorruptedRun(
            RunID(rawValue: runID),
            at: Date(timeIntervalSince1970: 102)
        )
        let audit = try #require(await store.record(for: RunID(rawValue: runID)))

        #expect(recoveryPage.records.isEmpty)
        #expect(recoveryPage.corruptedRunIDs == [RunID(rawValue: runID)])
        #expect(recoveryPage.recoveryRunIDs == [RunID(rawValue: runID)])
        #expect(didClose)
        #expect(audit.state == .cancelled)
        #expect(audit.finishedAt == Date(timeIntervalSince1970: 102))
        #expect(audit.transitions.starts(with: transitions))
        #expect(audit.writeTarget == target)
        #expect(audit.recoveryID == runID)
        #expect(audit.writeSummary == summary)
    }

    @Test("Corrupted recovery closure preserves a valid configuration")
    func preservesClosureConfig() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        let configuration = makeRunConfiguration(scopeID: scope.id, capturedAt: startedAt)
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(VersionedPayload(
                transitions: [],
                configuration: configuration
            )),
            input: RunRowInput(
                scopeData: JSONEncoder().encode(scope),
                intent: .writeFixes,
                state: .recoverable
            ),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        #expect(try await store.closeCorruptedRun(RunID(rawValue: runID), at: Date()))
        #expect(try await store.record(for: RunID(rawValue: runID))?.configuration == configuration)
    }

    @Test("Partial payload recovery preserves an independently valid configuration")
    func preservesPartialConfig() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        let configuration = makeRunConfiguration(scopeID: scope.id, capturedAt: startedAt)
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(CorruptedSummaryPayload(
                transitions: [
                    RunLifecycleTransition(state: .created, timestamp: startedAt),
                    RunLifecycleTransition(state: .recoverable, timestamp: startedAt.addingTimeInterval(1)),
                ],
                configuration: configuration
            )),
            input: RunRowInput(
                scopeData: JSONEncoder().encode(scope),
                intent: .writeFixes,
                state: .recoverable
            ),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        #expect(try await store.closeCorruptedRun(RunID(rawValue: runID), at: Date()))
        #expect(try await store.record(for: RunID(rawValue: runID))?.configuration == configuration)
    }

    @Test("Corrupted recovery closure drops a mismatched configuration")
    func dropsClosureConfig() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(VersionedPayload(
                transitions: [
                    RunLifecycleTransition(state: .created, timestamp: startedAt),
                    RunLifecycleTransition(state: .recoverable, timestamp: startedAt.addingTimeInterval(1)),
                ],
                configuration: makeRunConfiguration(scopeID: UUID(), capturedAt: startedAt)
            )),
            input: RunRowInput(
                scopeData: JSONEncoder().encode(scope),
                intent: .writeFixes,
                state: .recoverable
            ),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        #expect(try await store.closeCorruptedRun(RunID(rawValue: runID), at: Date()))
        #expect(try await store.record(for: RunID(rawValue: runID))?.configuration == nil)
    }

    @Test("Non-write headers with write evidence fail closed")
    func holdsConflictingWrite() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        let configuration = makeRunConfiguration(
            scopeID: scope.id,
            capturedAt: startedAt,
            writeAuthority: .reviewedPlan
        )
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(CorruptedSummaryPayload(
                transitions: [
                    RunLifecycleTransition(state: .created, timestamp: startedAt),
                    RunLifecycleTransition(state: .reporting, timestamp: startedAt.addingTimeInterval(1)),
                ],
                configuration: configuration
            )),
            input: RunRowInput(
                scopeData: JSONEncoder().encode(scope),
                intent: .observeLibrary,
                state: .reporting
            ),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        let page = try await store.recoveryRecords()

        #expect(page.recoveryRunIDs == [RunID(rawValue: runID)])
        #expect(page.closableRunIDs.isEmpty)
        #expect(page.attentionRunIDs.isEmpty)
        #expect(try await store.closeReadOnlyCorruption(RunID(rawValue: runID), at: Date()) == false)
        let finishedAt = Date(timeIntervalSince1970: 200)
        #expect(try await store.closeCorruptedRun(RunID(rawValue: runID), at: finishedAt))
        let audit = try #require(await store.record(for: RunID(rawValue: runID)))
        #expect(audit.intent == .writeFixes)
        #expect(audit.state == .cancelled)
        #expect(audit.recoveryID == runID)
        #expect(audit.finishedAt == finishedAt)
    }

    @Test("Missing v2 configuration requires write recovery")
    func holdsMissingConfig() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(MissingConfigPayload(transitions: [
                RunLifecycleTransition(state: .created, timestamp: startedAt),
                RunLifecycleTransition(state: .reporting, timestamp: startedAt.addingTimeInterval(1)),
            ])),
            input: RunRowInput(intent: .observeLibrary, state: .reporting),
            into: container
        )

        let page = try await RunRecordDataStore(modelContainer: container).recoveryRecords()

        #expect(page.recoveryRunIDs == [RunID(rawValue: runID)])
        #expect(page.closableRunIDs.isEmpty)
    }

    @Test("Malformed write evidence requires write recovery")
    func holdsMalformedWrite() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "manualCheck"
        )
        let configuration = makeRunConfiguration(scopeID: scope.id, capturedAt: startedAt)
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(MalformedWriteTargetPayload(
                transitions: [
                    RunLifecycleTransition(state: .created, timestamp: startedAt),
                    RunLifecycleTransition(state: .reporting, timestamp: startedAt.addingTimeInterval(1)),
                ],
                configuration: configuration
            )),
            input: RunRowInput(
                scopeData: JSONEncoder().encode(scope),
                intent: .observeLibrary,
                state: .reporting
            ),
            into: container
        )

        let page = try await RunRecordDataStore(modelContainer: container).recoveryRecords()

        #expect(page.recoveryRunIDs == [RunID(rawValue: runID)])
        #expect(page.closableRunIDs.isEmpty)
    }

    @Test("Corrupted scope preserves the configuration identity")
    func preservesScopeID() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let configuration = makeRunConfiguration(scopeID: UUID(), capturedAt: startedAt)
        try insertRunRow(
            runID: runID,
            transitionsData: JSONEncoder().encode(VersionedPayload(
                transitions: [
                    RunLifecycleTransition(state: .created, timestamp: startedAt),
                    RunLifecycleTransition(state: .recoverable, timestamp: startedAt.addingTimeInterval(1)),
                ],
                configuration: configuration
            )),
            input: RunRowInput(
                scopeData: Data([0xDE, 0xAD, 0xBE, 0xEF]),
                intent: .writeFixes,
                state: .recoverable
            ),
            into: container
        )
        let store = RunRecordDataStore(modelContainer: container)

        #expect(try await store.closeCorruptedRun(RunID(rawValue: runID), at: Date()))
        let audit = try #require(await store.record(for: RunID(rawValue: runID)))
        #expect(audit.configuration == configuration)
        #expect(audit.scope.id == configuration.scopeID)
    }
}

private struct FutureRunPayload: Encodable {
    let version = RunRecordPayload.currentVersion + 1
}
