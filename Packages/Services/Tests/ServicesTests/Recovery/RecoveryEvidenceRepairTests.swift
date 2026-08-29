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

        #expect(entry.id == item.id)
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

    @Test("a written artist rename rebuilds its coupled album artist evidence")
    func rebuildsCoupledArtistEntry() throws {
        let item = FixPlanItem(
            id: UUID(),
            identity: FixPlanItemIdentity(
                readID: "music-kit-1",
                appleScriptID: "persistent-1",
                artist: "Massive Attack",
                album: "Mezzanine",
                trackName: "Teardrop",
                albumArtist: "Massive Attack"
            ),
            changeType: .artistRename,
            oldValue: "Massive",
            newValue: "Massive Attack",
            confidence: 100,
            source: "Artist Renamer",
            albumArtistChange: AlbumArtistChange(
                oldValue: "Massive",
                newValue: "Massive Attack"
            )
        )

        let entry = try #require(RecoveryEvidenceRepair.changeLogEntry(for: RunWorkItem(item: item)))

        #expect(entry.oldArtist == "Massive")
        #expect(entry.newArtist == "Massive Attack")
        #expect(entry.albumArtistChange == item.albumArtistChange)
    }

    @Test("repair rejects a blank Music.app database ID")
    func rejectsBlankDatabaseID() {
        let item = FixPlanItem(
            id: UUID(),
            identity: FixPlanItemIdentity(
                readID: "music-kit-1",
                appleScriptID: "  \n",
                artist: "Massive Attack",
                album: "Mezzanine",
                trackName: "Teardrop"
            ),
            changeType: .genreUpdate,
            oldValue: "Electronic",
            newValue: "Trip-Hop",
            confidence: 100,
            source: "Library"
        )

        #expect(RecoveryEvidenceRepair.changeLogEntry(for: RunWorkItem(item: item)) == nil)
    }

    @Test("repair uses the reconciled write effect instead of stale plan evidence")
    func usesReconciledArtist() throws {
        let plannedEffect = AlbumArtistChange(oldValue: "Massive", newValue: "Massive Attack")
        let writeChange = WorkChange(
            changeType: .artistRename,
            oldValue: "Massive",
            newValue: "Massive Attack",
            confidence: 92,
            source: "Artist Renamer"
        )
        let item = makeWorkItem(
            state: .outcome(.written),
            changeType: .artistRename,
            oldValue: "Massive",
            newValue: "Massive Attack",
            source: "Artist Renamer",
            albumArtistChange: plannedEffect,
            writeChange: writeChange
        )

        let entry = try #require(RecoveryEvidenceRepair.changeLogEntry(for: item))

        #expect(entry.oldArtist == "Massive")
        #expect(entry.newArtist == "Massive Attack")
        #expect(entry.albumArtistChange == nil)
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

    @Test("finalization reuses matching durable history identity")
    func reusesDurableHistoryIdentity() throws {
        let runID = UUID()
        let landed = makeWorkItem(state: .outcome(.written), oldValue: "Rock", newValue: "Stoner Rock")
        let candidate = try #require(RecoveryEvidenceRepair.changeLogEntry(for: landed))
        var existing = ChangeLogEntry(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            changeType: candidate.changeType,
            trackID: candidate.trackID,
            artist: candidate.artist,
            trackName: candidate.trackName,
            albumName: candidate.albumName,
            oldGenre: candidate.oldGenre,
            newGenre: candidate.newGenre
        )
        existing.runID = runID

        let entries = RecoveryEvidenceRepair.finalizationEntries(
            for: [landed],
            existing: [existing],
            runID: runID
        )

        #expect(entries.map(\.id) == [existing.id])
    }

    @Test("finalization does not adopt a foreign run event with the same target effect")
    func keepsForeignHistorySeparate() throws {
        let runID = UUID()
        let landed = makeWorkItem(state: .outcome(.written), oldValue: "Rock", newValue: "Stoner Rock")
        let candidate = try #require(RecoveryEvidenceRepair.changeLogEntry(for: landed))
        var foreign = ChangeLogEntry(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            changeType: candidate.changeType,
            trackID: candidate.trackID,
            artist: candidate.artist,
            trackName: candidate.trackName,
            albumName: candidate.albumName,
            oldGenre: candidate.oldGenre,
            newGenre: candidate.newGenre
        )
        foreign.runID = UUID()

        let entries = RecoveryEvidenceRepair.finalizationEntries(
            for: [landed],
            existing: [foreign],
            runID: runID
        )

        #expect(entries.map(\.id) == [landed.id])
    }

    @Test("finalization does not reuse a same-run event with a different source effect")
    func keepsDistinctTransition() throws {
        let runID = UUID()
        let landed = makeWorkItem(state: .outcome(.written), oldValue: "Rock", newValue: "Stoner Rock")
        let candidate = try #require(RecoveryEvidenceRepair.changeLogEntry(for: landed))
        var existing = ChangeLogEntry(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            changeType: candidate.changeType,
            trackID: candidate.trackID,
            artist: candidate.artist,
            trackName: candidate.trackName,
            albumName: candidate.albumName,
            oldGenre: "Metal",
            newGenre: candidate.newGenre
        )
        existing.runID = runID

        let entries = RecoveryEvidenceRepair.finalizationEntries(
            for: [landed],
            existing: [existing],
            runID: runID
        )

        #expect(entries.map(\.id) == [landed.id])
    }

    @Test("same-run read identity is rewritten to the Music.app database ID")
    func rewritesSameRunReadID() {
        let runID = UUID()
        let landed = makeWorkItem(state: .outcome(.written), oldValue: "Rock", newValue: "Stoner Rock")
        let legacyID = UUID()
        var legacy = ChangeLogEntry(
            id: legacyID,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            changeType: .genreUpdate,
            trackID: "music-kit-1",
            artist: "Artist",
            trackName: "Track",
            albumName: "Album",
            oldGenre: "Rock",
            newGenre: "Stoner Rock"
        )
        legacy.runID = runID

        let entries = RecoveryEvidenceRepair.finalizationEntries(
            for: [landed],
            existing: [legacy],
            runID: runID
        )

        #expect(entries.map(\.id) == [legacyID])
        #expect(entries.map(\.trackID) == ["persistent-1"])
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
            trackID: "music-kit-1",
            artist: "Artist",
            trackName: "Track",
            albumName: "Album",
            oldGenre: "Rock",
            newGenre: "Stoner Rock"
        )
        legacy.runID = UUID()

        let entries = RecoveryEvidenceRepair.finalizationEntries(
            for: [landed],
            existing: [legacy],
            runID: runID
        )

        #expect(entries.count == 1)
        #expect(entries.first?.id != legacyID)
        #expect(entries.first?.trackID == "persistent-1")
    }
}
