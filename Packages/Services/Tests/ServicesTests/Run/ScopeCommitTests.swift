import Core
import Foundation
import Testing
@testable import Services

@Suite("Run scope commitment")
struct ScopeCommitTests {
    @Test("Manual observation publishes the scope committed by synchronization")
    func observationUsesCommittedScope() async throws {
        let scopeProbe = ScopeProbe()
        let certificateID = UUID(uuidString: "00000000-0000-0000-0000-000000000007")
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { capturedScope in
                await scopeProbe.record(capturedScope)
                return SyncResult(scope: capturedScope.binding(
                    revision: MirrorRevision(value: 7),
                    certificateID: certificateID
                ))
            },
            persistRunRecord: ignoreRunRecord,
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let result = await orchestrator.submit(.manualObservation(
            requestedTestArtists: ["Aphex Twin"],
            knownTrackCount: 75
        ))

        let capturedScope = try #require(await scopeProbe.scope)
        #expect(capturedScope.mirrorRevision == nil)
        #expect(capturedScope.certificateID == nil)
        #expect(result.lifecycle?.scope.id == capturedScope.id)
        #expect(result.lifecycle?.scope.mirrorRevision == MirrorRevision(value: 7))
        #expect(result.lifecycle?.scope.certificateID == certificateID)
    }

    @Test("Preview planning receives the scope committed by synchronization")
    func previewUsesCommittedScope() async throws {
        let scopeProbe = ScopeProbe()
        let configuration = FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(),
            capturedAt: Date(timeIntervalSince1970: 100)
        )
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { scope in SyncResult().committed(to: scope) },
            synchronizePreview: { scope, _, _ in
                SyncResult(scope: scope.binding(
                    revision: MirrorRevision(value: 11),
                    certificateID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")
                ))
            },
            persistRunRecord: ignoreRunRecord,
            produceFixPlan: { _, scope, _ in
                await scopeProbe.record(scope)
                return .empty
            },
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let result = await orchestrator.submit(.manualPreview(
            configuration: configuration,
            requestedTestArtists: ["Aphex Twin"],
            knownTrackCount: 75
        ))

        let plannedScope = try #require(await scopeProbe.scope)
        #expect(plannedScope.mirrorRevision == MirrorRevision(value: 11))
        #expect(plannedScope.certificateID == UUID(uuidString: "00000000-0000-0000-0000-000000000011"))
        #expect(result.lifecycle?.scope == plannedScope)
    }

    @Test("Preview persists committed scope before fix planning")
    func previewPersistsCommittedScopeBeforePlanning() async throws {
        let records = RunRecordProbe()
        let planningGate = SyncGate()
        let certificateID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")
        let configuration = FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(),
            capturedAt: Date(timeIntervalSince1970: 100)
        )
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { scope in
                SyncResult(scope: scope.binding(
                    revision: MirrorRevision(value: 12),
                    certificateID: certificateID
                ))
            },
            persistRunRecord: { try await records.append($0) },
            produceFixPlan: { _, _, _ in
                await planningGate.waitUntilReleased()
                return .empty
            },
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let submission = Task {
            await orchestrator.submit(.manualPreview(
                configuration: configuration,
                requestedTestArtists: ["Aphex Twin"],
                knownTrackCount: 75
            ))
        }
        await planningGate.waitUntilEntered()

        let openRecord = try #require(await records.records.last)
        #expect(openRecord.finishedAt == nil)
        #expect(openRecord.scope.mirrorRevision == MirrorRevision(value: 12))
        #expect(openRecord.scope.certificateID == certificateID)

        await planningGate.release()
        _ = await submission.value
    }

    @Test("Preview stops before planning when committed scope evidence cannot be persisted")
    func previewStopsOnScopePersistenceFailure() async throws {
        let records = CommittedScopeRecordSink()
        let producer = FixPlanProducerProbe(production: .empty)
        let configuration = FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(),
            capturedAt: Date(timeIntervalSince1970: 100)
        )
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { scope in
                SyncResult(scope: scope.binding(
                    revision: MirrorRevision(value: 12),
                    certificateID: UUID(uuidString: "00000000-0000-0000-0000-000000000012")
                ))
            },
            persistRunRecord: { try await records.append($0) },
            produceFixPlan: { runID, scope, _ in
                try await producer.produce(runID: runID, scope: scope)
            },
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let result = await orchestrator.submit(.manualPreview(
            configuration: configuration,
            requestedTestArtists: ["Aphex Twin"],
            knownTrackCount: 75
        ))

        #expect(result.lifecycle?.state == .failed)
        #expect(result.lifecycle?
            .failureMessage == "Committed library evidence could not be persisted before processing")
        #expect(await producer.callCount == 0)
        #expect(await records.records.allSatisfy { $0.scope.mirrorRevision == nil })
        let terminalRecord = try #require(await records.records.last)
        #expect(terminalRecord.finishedAt != nil)
        #expect(terminalRecord.failureMessage == "Committed library evidence could not be persisted before processing")
    }

    @Test("Preview rejects missing committed scope evidence")
    func previewRejectsMissingCommittedScope() async {
        let producer = FixPlanProducerProbe(production: .empty)
        let configuration = FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(),
            capturedAt: Date(timeIntervalSince1970: 100)
        )
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { _ in SyncResult() },
            persistRunRecord: ignoreRunRecord,
            produceFixPlan: { runID, scope, _ in
                try await producer.produce(runID: runID, scope: scope)
            },
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let result = await orchestrator.submit(.manualPreview(
            configuration: configuration,
            requestedTestArtists: ["Aphex Twin"],
            knownTrackCount: 75
        ))

        #expect(result.lifecycle?.state == .failed)
        #expect(await producer.callCount == 0)
    }

    @Test("Preview rejects unrelated committed scope evidence")
    func previewRejectsUnrelatedCommittedScope() async {
        let producer = FixPlanProducerProbe(production: .empty)
        let configuration = FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(),
            capturedAt: Date(timeIntervalSince1970: 100)
        )
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { scope in
                let unrelated = ProcessingScopeSnapshot.capture(
                    requestedTestArtists: scope.normalizedTestArtists,
                    knownTrackCount: scope.knownTrackCount,
                    createdAt: scope.createdAt,
                    reason: scope.reason
                )
                return SyncResult(scope: unrelated.binding(
                    revision: MirrorRevision(value: 13),
                    certificateID: UUID()
                ))
            },
            persistRunRecord: ignoreRunRecord,
            produceFixPlan: { runID, scope, _ in
                try await producer.produce(runID: runID, scope: scope)
            },
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let result = await orchestrator.submit(.manualPreview(
            configuration: configuration,
            requestedTestArtists: ["Aphex Twin"],
            knownTrackCount: 75
        ))

        #expect(result.lifecycle?.state == .failed)
        #expect(await producer.callCount == 0)
    }
}

private actor CommittedScopeRecordSink {
    private(set) var records: [RunRecord] = []

    func append(_ record: RunRecord) throws {
        guard record.scope.mirrorRevision == nil else {
            throw CommittedScopeRecordError()
        }
        records.append(record)
    }
}

private struct CommittedScopeRecordError: LocalizedError {
    var errorDescription: String? {
        "Committed scope evidence could not be persisted"
    }
}
