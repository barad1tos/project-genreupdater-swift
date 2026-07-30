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
