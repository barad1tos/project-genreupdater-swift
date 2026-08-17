import Foundation
import Testing
@testable import Core
@testable import Services

private struct YearUndoFixture {
    let bridge = MockAppleScriptClient()
    let historyStore = MockChangeLogStore()
    let trackStore = MockTrackStore()
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("YearUndoRecoveryTests-\(UUID().uuidString)")
    let entry: ChangeLogEntry

    init() {
        var entry = ChangeLogEntry(
            changeType: .yearUpdate,
            trackID: "T1",
            artist: "Massive Attack",
            trackName: "Angel",
            albumName: "Mezzanine"
        )
        entry.oldYear = nil
        entry.newYear = 2019
        self.entry = entry
    }

    var checkpointURL: URL {
        directory.appendingPathComponent("pending-year-revert.json")
    }

    func coordinator() -> UndoCoordinator {
        UndoCoordinator(
            scriptBridge: bridge,
            stores: .init(changeLog: historyStore, tracks: trackStore),
            directory: directory
        )
    }

    func prepare() async throws {
        let track = makeTrack(year: 2019)
        try await trackStore.saveTracks([track])
        await bridge.setFetchedTracks([track])
        try await coordinator().recordChange(entry)
    }

    func observe(year: Int?) async {
        await bridge.setFetchedTracks([makeTrack(year: year)])
    }

    private func makeTrack(year: Int?) -> Track {
        Track(
            id: "T1",
            name: "Angel",
            artist: "Massive Attack",
            album: "Mezzanine",
            year: year
        )
    }
}

@Suite("Empty-year undo recovery")
struct YearUndoRecoveryTests {
    @Test("Undoing a year added to an empty field writes the missing-year sentinel")
    func clearsAddedYear() async throws {
        let fixture = YearUndoFixture()
        try await fixture.prepare()
        let coordinator = fixture.coordinator()

        try await coordinator.revertChange(fixture.entry)

        #expect(await fixture.bridge.writtenProperties == [
            TrackPropertyUpdate(trackID: "T1", property: "year", value: "0"),
        ])
        #expect(await coordinator.getHistory().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.checkpointURL.path))
    }

    @Test("Legacy zero-year history uses the same empty-year undo")
    func revertsLegacyZero() async throws {
        let fixture = YearUndoFixture()
        var entry = fixture.entry
        entry.oldYear = MusicAppYear.missingValue
        let currentTrack = Track(
            id: "T1",
            name: "Angel",
            artist: "Massive Attack",
            album: "Mezzanine",
            year: 2019
        )
        try await fixture.trackStore.saveTracks([currentTrack])
        await fixture.bridge.setFetchedTracks([currentTrack])
        let coordinator = fixture.coordinator()
        try await coordinator.recordChange(entry)

        try await coordinator.revertChange(entry)

        #expect(await fixture.bridge.writtenProperties == [
            TrackPropertyUpdate(trackID: "T1", property: "year", value: "0"),
        ])
        #expect(await coordinator.getHistory().isEmpty)
    }

    @Test("Unknown write observed as empty finalizes without another dispatch")
    func unknownWriteLanded() async throws {
        let fixture = YearUndoFixture()
        try await fixture.prepare()
        await fixture.bridge.setCustomWriteError(Self.unknownOutcome)

        await expectUnknownOutcome {
            try await fixture.coordinator().revertChange(fixture.entry)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.checkpointURL.path))
        #expect(await fixture.historyStore.entries == [fixture.entry])

        await fixture.bridge.setCustomWriteError(nil)
        await fixture.observe(year: nil)
        try await fixture.coordinator().revertChange(fixture.entry)

        #expect(await fixture.bridge.writtenProperties.isEmpty)
        #expect(await fixture.historyStore.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.checkpointURL.path))
        let mirrored = try await fixture.trackStore.getTrack(byID: "T1")
        #expect(mirrored?.year == nil)
        #expect(mirrored?.yearBeforeMGU == MusicAppYear.missingValue)
        #expect(mirrored?.yearSetByMGU == MusicAppYear.missingValue)
    }

    @Test("Unknown write observed at source becomes a fresh retry")
    func unknownWriteMissed() async throws {
        let fixture = YearUndoFixture()
        try await fixture.prepare()
        await fixture.bridge.setCustomWriteError(Self.unknownOutcome)

        await expectUnknownOutcome {
            try await fixture.coordinator().revertChange(fixture.entry)
        }
        await fixture.bridge.setCustomWriteError(nil)

        await expectRecoveryFailure(effects: ["undo write did not take effect"]) {
            try await fixture.coordinator().revertChange(fixture.entry)
        }
        #expect(await fixture.bridge.writtenProperties.isEmpty)
        #expect(await fixture.historyStore.entries == [fixture.entry])
        #expect(!FileManager.default.fileExists(atPath: fixture.checkpointURL.path))

        try await fixture.coordinator().revertChange(fixture.entry)

        #expect(await fixture.bridge.writtenProperties == [
            TrackPropertyUpdate(trackID: "T1", property: "year", value: "0"),
        ])
        #expect(await fixture.historyStore.entries.isEmpty)
    }

    @Test("Unknown write observed at a third value remains blocked")
    func unknownWriteConflicts() async throws {
        let fixture = YearUndoFixture()
        try await fixture.prepare()
        await fixture.bridge.setCustomWriteError(Self.unknownOutcome)

        await expectUnknownOutcome {
            try await fixture.coordinator().revertChange(fixture.entry)
        }
        await fixture.bridge.setCustomWriteError(nil)
        await fixture.observe(year: 2020)

        await expectRecoveryFailure(effects: ["ambiguous undo write outcome"]) {
            try await fixture.coordinator().revertChange(fixture.entry)
        }

        #expect(await fixture.bridge.writtenProperties.isEmpty)
        #expect(await fixture.historyStore.entries == [fixture.entry])
        #expect(FileManager.default.fileExists(atPath: fixture.checkpointURL.path))
    }

    @Test("Mirror failure after a landed clear resumes without another dispatch")
    func resumesMirrorFailure() async throws {
        let fixture = YearUndoFixture()
        try await fixture.prepare()
        await fixture.trackStore.failAppliedUpdates()

        await expectRecoveryFailure(effects: ["track mirror"]) {
            try await fixture.coordinator().revertChange(fixture.entry)
        }
        #expect(await fixture.bridge.writtenProperties.count == 1)
        #expect(await fixture.historyStore.entries == [fixture.entry])
        #expect(FileManager.default.fileExists(atPath: fixture.checkpointURL.path))

        await fixture.trackStore.resumeAppliedUpdates()
        try await fixture.coordinator().revertChange(fixture.entry)

        #expect(await fixture.bridge.writtenProperties.count == 1)
        #expect(await fixture.historyStore.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.checkpointURL.path))
        let mirrored = try await fixture.trackStore.getTrack(byID: "T1")
        #expect(mirrored?.year == nil)
        #expect(mirrored?.yearBeforeMGU == MusicAppYear.missingValue)
        #expect(mirrored?.yearSetByMGU == MusicAppYear.missingValue)
    }

    @Test("Mirror recovery keeps the oldest year origin")
    func recoversOldestOrigin() async throws {
        let fixture = YearUndoFixture()
        let currentTrack = Track(
            id: "T1",
            name: "Angel",
            artist: "Massive Attack",
            album: "Mezzanine",
            year: 2020
        )
        var oldestEntry = fixture.entry
        oldestEntry.oldYear = 1998
        oldestEntry.newYear = 2019
        var latestEntry = ChangeLogEntry(
            changeType: .yearUpdate,
            trackID: "T1",
            artist: "Massive Attack",
            trackName: "Angel",
            albumName: "Mezzanine"
        )
        latestEntry.oldYear = 2019
        latestEntry.newYear = 2020
        try await fixture.trackStore.saveTracks([currentTrack])
        await fixture.bridge.setFetchedTracks([currentTrack])
        let coordinator = fixture.coordinator()
        try await coordinator.recordChanges([oldestEntry, latestEntry])
        await fixture.trackStore.failAppliedUpdates()

        await expectRecoveryFailure(effects: ["track mirror"]) {
            try await coordinator.revertChange(latestEntry)
        }
        await fixture.trackStore.resumeAppliedUpdates()
        try await fixture.coordinator().revertChange(latestEntry)

        let mirrored = try await fixture.trackStore.getTrack(byID: "T1")
        #expect(mirrored?.year == 2019)
        #expect(mirrored?.yearBeforeMGU == 1998)
        #expect(mirrored?.yearSetByMGU == 2019)
        #expect(await fixture.bridge.writtenProperties.count == 1)
    }

    private static let unknownOutcome = AppleScriptOutcomeError(
        scriptName: "update_property",
        reason: "test outcome unknown"
    )

    private func expectUnknownOutcome(operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("Expected AppleScript outcome error")
        } catch is AppleScriptOutcomeError {
            // Expected: the checkpoint must resolve the unknown dispatch on retry.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func expectRecoveryFailure(
        effects expectedEffects: [String],
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected recovery failure")
        } catch let error as UpdateCoordinatorError {
            guard case let .writeFinalizationFailed(trackID, effects) = error else {
                Issue.record("Expected writeFinalizationFailed, got \(error)")
                return
            }
            #expect(trackID == "T1")
            #expect(effects == expectedEffects)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
