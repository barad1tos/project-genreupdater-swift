import Core
import Foundation
import Testing
@testable import Services

@Suite("Recovery evidence repair")
struct RecoveryEvidenceRepairTests {
    @Test("a written genre item rebuilds its history entry")
    func rebuildsGenreEntry() throws {
        let item = makeWorkItem(state: .outcome(.written), oldValue: "Rock", newValue: "Stoner Rock")

        let entry = try #require(RecoveryEvidenceRepair.changeLogEntry(for: item))

        #expect(entry.trackID == "music-kit-1")
        #expect(entry.changeType == .genreUpdate)
        #expect(entry.oldGenre == "Rock")
        #expect(entry.newGenre == "Stoner Rock")
        #expect(entry.artist == "Artist")
        #expect(entry.albumName == "Album")
    }

    @Test("a written year item rebuilds numeric values")
    func rebuildsYearEntry() throws {
        let item = makeWorkItem(
            state: .outcome(.written),
            changeType: .yearUpdate,
            oldValue: "1999",
            newValue: "2001"
        )

        let entry = try #require(RecoveryEvidenceRepair.changeLogEntry(for: item))

        #expect(entry.oldYear == 1999)
        #expect(entry.newYear == 2001)
    }

    @Test("written items cover checkpointed terminals and observed writes")
    func collectsWrittenItems() {
        let terminal = makeWorkItem(state: .outcome(.written), oldValue: "Rock", newValue: "Stoner Rock")
        let observedWritten = makeWorkItem(state: .attempted, oldValue: "Pop", newValue: "Synthpop")
        let observedFailed = makeWorkItem(state: .attempted, oldValue: "Ska", newValue: "Dub")
        let terminalFailed = makeWorkItem(state: .outcome(.failed), oldValue: "Jazz", newValue: "Bebop")

        let written = RecoveryEvidenceRepair.writtenItems(
            in: [terminal, observedWritten, observedFailed, terminalFailed],
            observed: [
                observedWritten.id: ObservedWorkOutcome(outcome: .written, observedValue: "Synthpop"),
                observedFailed.id: ObservedWorkOutcome(outcome: .failed, observedValue: "Ska"),
            ]
        )

        #expect(written.map(\.id) == [terminal.id, observedWritten.id])
    }

    @Test("terminal written items repair without any observation")
    func repairsTerminalWithoutObservation() {
        let terminal = makeWorkItem(state: .outcome(.written), oldValue: "Rock", newValue: "Stoner Rock")

        let written = RecoveryEvidenceRepair.writtenItems(in: [terminal], observed: nil)

        #expect(written.map(\.id) == [terminal.id])
    }

    @Test("repair skips entries the history already records")
    func filtersMissingEntries() throws {
        let landed = makeWorkItem(state: .outcome(.written), oldValue: "Rock", newValue: "Stoner Rock")
        let recorded = makeWorkItem(
            state: .outcome(.written),
            changeType: .yearUpdate,
            oldValue: "1999",
            newValue: "2001"
        )
        let existing = try #require(RecoveryEvidenceRepair.changeLogEntry(for: recorded))

        let entries = RecoveryEvidenceRepair.missingEntries(
            for: [landed, recorded],
            existing: [existing]
        )

        #expect(entries.map(\.newGenre) == ["Stoner Rock"])
    }

    @Test("repair is idempotent across repeated clearance attempts")
    func staysIdempotent() {
        let landed = makeWorkItem(state: .outcome(.written), oldValue: "Rock", newValue: "Stoner Rock")
        let first = RecoveryEvidenceRepair.missingEntries(for: [landed], existing: [])

        let second = RecoveryEvidenceRepair.missingEntries(for: [landed], existing: first)

        #expect(first.count == 1)
        #expect(second.isEmpty)
    }
}
