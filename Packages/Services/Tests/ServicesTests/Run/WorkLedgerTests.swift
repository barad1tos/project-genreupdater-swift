import Core
import Foundation
import Testing
@testable import Services

@Suite("Work ledger")
struct WorkLedgerTests {
    @Test("checkpoint updates preserve order and prior values")
    func preservesValueSnapshots() throws {
        let first = makeWorkItem(state: .prepared)
        let second = makeWorkItem(state: .prepared)
        let original = WorkLedger([first, second])

        let attempting = try original.applying(.beforeAttempt([second.id]))

        #expect(original.items.map(\.state) == [.prepared, .prepared])
        #expect(!original.hasDuplicateItems)
        #expect(attempting.items.map(\.id) == [first.id, second.id])
        #expect(attempting.items.map(\.state) == [.prepared, .attempting])
        #expect(attempting.hasOpenItems)
        #expect(attempting.hasUncertainty)
        #expect(attempting.hasProgress)
    }

    @Test("before-attempt checkpoint retains the authoritative write effect")
    func retainsWriteChange() throws {
        let plannedEffect = AlbumArtistChange(oldValue: "Massive", newValue: "Massive Attack")
        let item = makeWorkItem(
            state: .prepared,
            changeType: .artistRename,
            oldValue: "Massive",
            newValue: "Massive Attack",
            albumArtistChange: plannedEffect
        )
        let writeChange = WorkChange(
            changeType: .artistRename,
            oldValue: "Massive",
            newValue: "Massive Attack",
            confidence: item.change.confidence,
            source: item.change.source
        )

        let ledger = try WorkLedger([item]).applying(.beforeAttempt([item.id: writeChange]))

        #expect(ledger.items.first?.writeChange == writeChange)
        #expect(ledger.items.first?.effectiveChange == writeChange)
    }

    @Test("before-attempt checkpoint rejects a different primary effect")
    func rejectsChangedWriteEffect() {
        let item = makeWorkItem(state: .prepared, oldValue: "Rock", newValue: "Metal")
        let differentChange = WorkChange(
            changeType: .genreUpdate,
            oldValue: "Rock",
            newValue: "Jazz",
            confidence: item.change.confidence,
            source: item.change.source
        )

        #expect(throws: WorkCheckpointError.self) {
            try WorkLedger([item]).applying(.beforeAttempt([item.id: differentChange]))
        }
    }

    @Test("unknown checkpoint work rejects the entire update")
    func rejectsUnknownWork() {
        let item = makeWorkItem(state: .prepared)
        let ledger = WorkLedger([item])

        #expect(throws: WorkCheckpointError.self) {
            try ledger.applying(.beforeAttempt([item.id, UUID()]))
        }
        #expect(ledger.items == [item])
    }

    @Test("unknown item on a post-dispatch boundary needs recovery")
    func classifiesUnknownPostDispatchWork() {
        let ledger = WorkLedger([])

        do {
            _ = try ledger.applying(.afterAttempt([UUID()]))
            Issue.record("Expected an invalid checkpoint error")
        } catch let error as WorkCheckpointError {
            #expect(error.needsRecovery)
        } catch {
            Issue.record("Expected WorkCheckpointError, got \(error)")
        }
    }

    @Test("duplicate input remains visible and rejects checkpoints")
    func preservesDuplicateEvidence() {
        let itemID = UUID()
        let first = makeWorkItem(id: itemID, state: .prepared)
        let duplicate = makeWorkItem(id: itemID, state: .attempting)
        let ledger = WorkLedger([first, duplicate])

        #expect(ledger.items == [first, duplicate])
        #expect(ledger.hasDuplicateItems)
        #expect(ledger.isWriteAdjacent(to: .afterAttempt([itemID])))
        #expect(throws: WorkCheckpointError.self) {
            try ledger.applying(.afterAttempt([itemID]))
        }
    }

    @Test("terminal counters distinguish written progress from uncertainty")
    func derivesTerminalCounters() throws {
        let item = makeWorkItem(state: .prepared)
        let prepared = WorkLedger([item])
        let attempting = try prepared.applying(.beforeAttempt([item.id]))
        let attempted = try attempting.applying(.afterAttempt([item.id]))
        let written = try attempted.applying(.afterVerification([item.id: .written]))

        #expect(prepared.hasOpenItems)
        #expect(!prepared.hasUncertainty)
        #expect(!prepared.hasProgress)
        #expect(attempting.hasUncertainty)
        #expect(attempted.hasUncertainty)
        #expect(!written.hasOpenItems)
        #expect(!written.hasUncertainty)
        #expect(written.hasProgress)
    }

    @Test("attempting and attempted work are both uncertain")
    func tracksUncertainty() throws {
        let item = makeWorkItem(state: .prepared)
        let prepared = WorkLedger([item])
        let attempting = try prepared.applying(.beforeAttempt([item.id]))
        let attempted = try attempting.applying(.afterAttempt([item.id]))

        #expect(!prepared.hasUncertainty)
        #expect(attempting.hasUncertainty)
        #expect(attempted.hasUncertainty)
    }

    @Test("a no-op or skip verification resolves an undispatched attempt as-is")
    func recordsFallbackNoOp() throws {
        let noOpItem = makeWorkItem(state: .prepared)
        let skipItem = makeWorkItem(state: .prepared)
        let ledger = try WorkLedger([noOpItem, skipItem])
            .applying(.beforeAttempt([noOpItem.id, skipItem.id]))

        let resolved = try ledger
            .applying(.afterVerification([noOpItem.id: .noFixNeeded]))
            .applying(.afterVerification([skipItem.id: .skipped]))

        #expect(resolved.items.map(\.state) == [.outcome(.noFixNeeded), .outcome(.skipped)])
        #expect(!resolved.hasUncertainty)
        #expect(!resolved.hasOpenItems)
    }

    @Test("a no-op verification on a prepared item is unchanged")
    func keepsPreparedNoOp() throws {
        let item = makeWorkItem(state: .prepared)
        let resolved = try WorkLedger([item]).applying(.afterVerification([item.id: .noFixNeeded]))

        #expect(resolved.items.first?.state == .outcome(.noFixNeeded))
    }

    @Test(
        "per-item checkpoints scale to a full library",
        .timeLimit(.minutes(1))
    )
    func scalesCheckpoints() throws {
        let items = (0 ..< 10000).map { _ in makeWorkItem(state: .prepared) }
        var ledger = WorkLedger(items)

        for item in items {
            ledger = try ledger.applying(.beforeAttempt([item.id]))
            ledger = try ledger.applying(.afterAttempt([item.id]))
            ledger = try ledger.applying(.afterVerification([item.id: .written]))
        }

        #expect(!ledger.hasOpenItems)
        #expect(!ledger.hasUncertainty)
        #expect(ledger.hasProgress)
        #expect(ledger.items.allSatisfy { $0.state == .outcome(.written) })
    }
}
