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
        let runID = UUID()
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
            existing: [existing],
            runID: runID
        )

        #expect(entries.map(\.newGenre) == ["Stoner Rock"])
    }

    @Test("repair is idempotent across repeated clearance attempts")
    func staysIdempotent() {
        let runID = UUID()
        let landed = makeWorkItem(state: .outcome(.written), oldValue: "Rock", newValue: "Stoner Rock")
        let first = RecoveryEvidenceRepair.missingEntries(for: [landed], existing: [], runID: runID)

        let second = RecoveryEvidenceRepair.missingEntries(for: [landed], existing: first, runID: runID)

        #expect(first.count == 1)
        #expect(second.isEmpty)
    }

    @Test("legacy history from another run is not migrated")
    func keepsForeignHistory() {
        let runID = UUID()
        let landed = makeWorkItem(state: .outcome(.written), oldValue: "Rock", newValue: "Stoner Rock")
        let legacyID = UUID()
        var legacy = ChangeLogEntry(
            id: legacyID,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            changeType: .genreUpdate,
            trackID: "persistent-1",
            artist: "Artist",
            trackName: "Track",
            albumName: "Album",
            oldGenre: "Rock",
            newGenre: "Stoner Rock"
        )
        legacy.runID = UUID()

        let entries = RecoveryEvidenceRepair.missingEntries(
            for: [landed],
            existing: [legacy],
            runID: runID
        )

        #expect(entries.count == 1)
        #expect(entries.first?.id != legacyID)
        #expect(entries.first?.trackID == "music-kit-1")
    }

    @Test("failed repaired save keeps legacy history until retry")
    func retriesFailedRepair() async throws {
        let store = MockChangeLogStore()
        let coordinator = UndoCoordinator(
            scriptBridge: MockAppleScriptClient(),
            changeLogStore: store,
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("RecoveryRepair-\(UUID().uuidString)")
        )
        let legacy = ChangeLogEntry(
            changeType: .genreUpdate,
            trackID: "persistent-1",
            artist: "Artist"
        )
        try await coordinator.recordChange(legacy)
        let canonical = ChangeLogEntry(
            id: legacy.id,
            timestamp: legacy.timestamp,
            changeType: legacy.changeType,
            trackID: "read-1",
            artist: legacy.artist,
            oldGenre: "Rock",
            newGenre: "Stoner Rock"
        )
        await store.failSaves()

        await #expect(throws: MockScriptError.self) {
            try await coordinator.recordRepairedChanges([canonical])
        }
        #expect(await coordinator.getHistory().map(\.trackID) == ["persistent-1"])
        #expect(try await store.loadAll().map(\.trackID) == ["persistent-1"])

        await store.resumeSaves()
        try await coordinator.recordRepairedChanges([canonical])

        #expect(await coordinator.getHistory().map(\.trackID) == ["read-1"])
        #expect(try await store.loadAll().map(\.trackID) == ["read-1"])
    }
}
