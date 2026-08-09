import Core
import Foundation
import Testing
@testable import Services

@Suite("Run observation")
struct RunObservationTests {
    @Test("manual observation skips fix planning")
    func skipsFixPlanning() async throws {
        let records = RecordProbe()
        let plans = PlanProbe()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: {
                SyncResult(newTracks: [
                    Track(id: "NEW", name: "Track", artist: "Artist", album: "Album")
                ])
            },
            persistRunRecord: { try await records.append($0) },
            produceFixPlan: { runID, scope, _ in
                try await plans.produce(runID: runID, scope: scope)
            },
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let result = await orchestrator.submit(.manualObservation(
            requestedTestArtists: [],
            knownTrackCount: nil
        ))

        guard case .completed = result else {
            Issue.record("Expected completed, got \(result)")
            return
        }

        let final = try #require(await records.items.last)
        #expect(await plans.calls.isEmpty)
        #expect(final.intent == .observeLibrary)
        #expect(final.transitions.map(\.state) == [.created, .syncingLibrary, .reporting, .completed])
    }
}

@Suite("Incremental cadence hook")
struct IncrementalCadenceHookTests {
    @Test("completed observation fires the hook once")
    func completedObservationFires() async throws {
        let hook = HookProbe()
        let orchestrator = makeOrchestrator(
            syncResult: SyncResult(newTracks: [
                Track(id: "NEW", name: "Track", artist: "Artist", album: "Album")
            ]),
            hook: hook
        )

        let request = RunRequest.observation(
            trigger: .backgroundSync,
            requestedTestArtists: [],
            knownTrackCount: nil
        )
        let result = await orchestrator.submit(request)

        guard case .completed = result else {
            Issue.record("Expected completed, got \(result)")
            return
        }
        #expect(await hook.count == 1)
    }

    @Test("no-op observation never advances the mark")
    func noOpObservationDoesNotFire() async throws {
        let hook = HookProbe()
        let orchestrator = makeOrchestrator(syncResult: SyncResult(), hook: hook)

        let request = RunRequest.observation(
            trigger: .backgroundSync,
            requestedTestArtists: [],
            knownTrackCount: nil
        )
        let result = await orchestrator.submit(request)

        guard case .completedNoOp = result else {
            Issue.record("Expected completedNoOp, got \(result)")
            return
        }
        #expect(await hook.count == 0)
    }

    @Test("failed observation never advances the mark")
    func failedObservationDoesNotFire() async throws {
        let hook = HookProbe()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { throw SyncFailure.unavailable },
            persistRunRecord: { _ in },
            onIncrementalWorkCompleted: { await hook.fire() },
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let result = await orchestrator.submit(.manualObservation(
            requestedTestArtists: [],
            knownTrackCount: nil
        ))

        guard case .failed = result else {
            Issue.record("Expected failed, got \(result)")
            return
        }
        #expect(await hook.count == 0)
    }

    @Test("manual check advances through the same hook")
    func manualObservationFires() async throws {
        let hook = HookProbe()
        let orchestrator = makeOrchestrator(
            syncResult: SyncResult(newTracks: [
                Track(id: "NEW", name: "Track", artist: "Artist", album: "Album")
            ]),
            hook: hook
        )

        let result = await orchestrator.submit(.manualObservation(
            requestedTestArtists: [],
            knownTrackCount: nil
        ))

        guard case .completed = result else {
            Issue.record("Expected completed, got \(result)")
            return
        }
        #expect(await hook.count == 1)
    }

    @Test("completed preview stays outside the cadence contract")
    func completedPreviewDoesNotFire() async throws {
        let hook = HookProbe()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: {
                SyncResult(newTracks: [
                    Track(id: "NEW", name: "Track", artist: "Artist", album: "Album")
                ])
            },
            persistRunRecord: { _ in },
            produceFixPlan: { _, _, _ in
                FixPlanProduction(planID: FixPlanID(), proposalCount: 1)
            },
            onIncrementalWorkCompleted: { await hook.fire() },
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let configuration = FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(),
            capturedAt: Date(timeIntervalSince1970: 100)
        )
        let result = await orchestrator.submit(.manualPreview(
            configuration: configuration,
            requestedTestArtists: [],
            knownTrackCount: nil
        ))

        guard case .completed = result else {
            Issue.record("Expected completed, got \(result)")
            return
        }
        #expect(await hook.count == 0)
    }

    private func makeOrchestrator(syncResult: SyncResult, hook: HookProbe) -> RunOrchestrator {
        RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { syncResult },
            persistRunRecord: { _ in },
            onIncrementalWorkCompleted: { await hook.fire() },
            now: { Date(timeIntervalSince1970: 100) }
        ))
    }
}

private enum SyncFailure: Error {
    case unavailable
}

private actor HookProbe {
    private(set) var count = 0

    func fire() {
        count += 1
    }
}

private actor PlanProbe {
    private(set) var calls: [(RunID, ProcessingScopeSnapshot)] = []

    func produce(runID: RunID, scope: ProcessingScopeSnapshot) throws -> FixPlanProduction {
        calls.append((runID, scope))
        return .empty
    }
}

private actor RecordProbe {
    private(set) var items: [RunRecord] = []

    func append(_ record: RunRecord) throws {
        items.append(record)
    }
}
