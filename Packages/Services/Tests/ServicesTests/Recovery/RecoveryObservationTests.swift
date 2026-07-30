import Core
import Foundation
import Testing
@testable import Services

@Suite("Recovery observation classification")
struct RecoveryObservationTests {
    @Test("observed intended value classifies written")
    func classifiesWritten() {
        let item = makeWorkItem(state: .attempted, oldValue: "Rock", newValue: "Stoner Rock")

        #expect(RecoveryObservation.outcome(for: item, observedValue: "Stoner Rock") == .written)
    }

    @Test("observed prior value classifies failed without retry")
    func classifiesFailed() {
        let item = makeWorkItem(state: .attempted, oldValue: "Rock", newValue: "Stoner Rock")

        #expect(RecoveryObservation.outcome(for: item, observedValue: "Rock") == .failed)
    }

    @Test("observed external value needs review")
    func classifiesExternalChange() {
        let item = makeWorkItem(state: .attempted, oldValue: "Rock", newValue: "Stoner Rock")

        #expect(RecoveryObservation.outcome(for: item, observedValue: "Jazz") == .needsReview)
    }

    @Test("absent track needs review")
    func classifiesAbsentTrack() {
        let item = makeWorkItem(state: .attempted, oldValue: "Rock", newValue: "Stoner Rock")

        #expect(RecoveryObservation.outcome(for: item, observedValue: nil) == .needsReview)
    }

    @Test("empty observed value matches a nil prior value as failed")
    func treatsEmptyAsNilPrior() {
        let item = makeWorkItem(state: .attempted, oldValue: nil, newValue: "1999")

        #expect(RecoveryObservation.outcome(for: item, observedValue: "") == .failed)
    }
}

@Suite("Recovery observation service")
struct RecoveryObservationServiceTests {
    @Test("observed live value classifies landed and externally changed items")
    func observesUncertainItems() async throws {
        let landed = makeWorkItem(state: .attempted, oldValue: "Rock", newValue: "Stoner Rock")
        let external = makeWorkItem(state: .attempting, oldValue: "Pop", newValue: "Synthpop")
        let client = MockAppleScriptClient()
        await client.setFetchedTracks([
            observedTrack(id: "persistent-1", genre: "Stoner Rock"),
        ])
        let service = RecoveryObservationService(scriptClient: client)

        let outcomes = try await service.observeOutcomes(for: [landed, external])

        #expect(outcomes[landed.id] == .written)
        #expect(outcomes[external.id] == .needsReview)
    }

    @Test("absent live track needs review")
    func classifiesAbsentTrack() async throws {
        let attempted = makeWorkItem(state: .attempted)
        let client = MockAppleScriptClient()
        let service = RecoveryObservationService(scriptClient: client)

        let outcomes = try await service.observeOutcomes(for: [attempted])

        #expect(outcomes[attempted.id] == .needsReview)
    }

    @Test("prepared items skip without observation")
    func skipsPreparedWithoutFetch() async throws {
        let prepared = makeWorkItem(state: .prepared)
        let client = MockAppleScriptClient()
        let service = RecoveryObservationService(scriptClient: client)

        let outcomes = try await service.observeOutcomes(for: [prepared])

        #expect(outcomes[prepared.id] == .skipped)
        #expect(await client.fetchTracksByIDsCalls().isEmpty)
    }

    @Test("terminal items are not observed")
    func ignoresTerminalItems() async throws {
        let terminal = makeWorkItem(state: .outcome(.written))
        let client = MockAppleScriptClient()
        let service = RecoveryObservationService(scriptClient: client)

        let outcomes = try await service.observeOutcomes(for: [terminal])

        #expect(outcomes.isEmpty)
    }

    @Test("fetch failure propagates and blocks clearance")
    func propagatesFetchFailure() async {
        let attempted = makeWorkItem(state: .attempted)
        let client = MockAppleScriptClient()
        await client.setFetchThrowMode(true)
        let service = RecoveryObservationService(scriptClient: client)

        await #expect(throws: (any Error).self) {
            _ = try await service.observeOutcomes(for: [attempted])
        }
    }
}

private func observedTrack(id: String, genre: String) -> Track {
    Track(
        id: id,
        name: "Track",
        artist: "Artist",
        album: "Album",
        genre: genre
    )
}

@Suite("Work ledger observed outcomes")
struct ObservedOutcomeLedgerTests {
    @Test("observed outcomes close every open item")
    func closesOpenItems() throws {
        let attempted = makeWorkItem(state: .attempted)
        let prepared = makeWorkItem(state: .prepared)
        let ledger = WorkLedger([attempted, prepared])

        let closed = try ledger.applyingObservedOutcomes([
            attempted.id: .written,
            prepared.id: .skipped,
        ])

        #expect(closed.items.map(\.state) == [.outcome(.written), .outcome(.skipped)])
        #expect(!closed.hasOpenItems)
        #expect(!closed.hasUncertainty)
    }

    @Test("observed written closes an attempting item through the attempt boundary")
    func promotesAttemptingToWritten() throws {
        let attempting = makeWorkItem(state: .attempting)
        let ledger = WorkLedger([attempting])

        let closed = try ledger.applyingObservedOutcomes([attempting.id: .written])

        #expect(closed.items.map(\.state) == [.outcome(.written)])
    }

    @Test("missing observed outcome for an open item is rejected")
    func rejectsIncompleteCoverage() {
        let attempted = makeWorkItem(state: .attempted)
        let prepared = makeWorkItem(state: .prepared)
        let ledger = WorkLedger([attempted, prepared])

        #expect(throws: WorkCheckpointError.self) {
            _ = try ledger.applyingObservedOutcomes([attempted.id: .written])
        }
    }

    @Test("terminal items are left untouched by observed outcomes")
    func preservesTerminalItems() throws {
        let written = makeWorkItem(state: .outcome(.failed))
        let attempted = makeWorkItem(state: .attempted)
        let ledger = WorkLedger([written, attempted])

        let closed = try ledger.applyingObservedOutcomes([attempted.id: .noFixNeeded])

        #expect(closed.items.map(\.state) == [.outcome(.failed), .outcome(.noFixNeeded)])
    }
}
