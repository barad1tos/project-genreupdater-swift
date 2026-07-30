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

        #expect(entry.trackID == "persistent-1")
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

    @Test("repair covers only observed-written items missing from history")
    func filtersMissingEntries() throws {
        let landed = makeWorkItem(state: .outcome(.written), oldValue: "Rock", newValue: "Stoner Rock")
        let failed = makeWorkItem(state: .outcome(.failed), oldValue: "Pop", newValue: "Synthpop")
        let recorded = makeWorkItem(
            state: .outcome(.written),
            changeType: .yearUpdate,
            oldValue: "1999",
            newValue: "2001"
        )
        let existing = try #require(RecoveryEvidenceRepair.changeLogEntry(for: recorded))

        let entries = RecoveryEvidenceRepair.missingEntries(
            for: [landed, failed, recorded],
            observed: [
                landed.id: ObservedWorkOutcome(outcome: .written, observedValue: "Stoner Rock"),
                failed.id: ObservedWorkOutcome(outcome: .failed, observedValue: "Pop"),
                recorded.id: ObservedWorkOutcome(outcome: .written, observedValue: "2001"),
            ],
            existing: [existing]
        )

        #expect(entries.map(\.newGenre) == ["Stoner Rock"])
    }

    @Test("repair is idempotent across repeated clearance attempts")
    func staysIdempotent() throws {
        let landed = makeWorkItem(state: .outcome(.written), oldValue: "Rock", newValue: "Stoner Rock")
        let observed = [landed.id: ObservedWorkOutcome(outcome: .written, observedValue: "Stoner Rock")]
        let first = RecoveryEvidenceRepair.missingEntries(for: [landed], observed: observed, existing: [])

        let second = RecoveryEvidenceRepair.missingEntries(
            for: [landed],
            observed: observed,
            existing: first
        )

        #expect(first.count == 1)
        #expect(second.isEmpty)
    }
}
