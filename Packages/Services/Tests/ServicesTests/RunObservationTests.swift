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
            produceFixPlan: { try await plans.produce(runID: $0, scope: $1) },
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
