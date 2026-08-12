import Foundation
import Testing
@testable import Core
@testable import Services

private struct BackupRecoveryFixture {
    let bridge: MockAppleScriptClient
    let historyStore: MockChangeLogStore
    let trackStore: MockTrackStore
    let directory: URL
    let liveTrack: Track
    let csv: String

    static func make() async throws -> Self {
        let bridge = MockAppleScriptClient()
        let historyStore = MockChangeLogStore()
        let trackStore = MockTrackStore()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupRecoveryTests-\(UUID().uuidString)")
        let staleMirror = Track(
            id: "T1",
            name: "Angel",
            artist: "Massive Attack",
            album: "Mezzanine",
            year: 2019
        )
        var liveTrack = staleMirror
        liveTrack.year = 1998
        try await trackStore.saveTracks([staleMirror])
        await bridge.setFetchedTracks([liveTrack])
        return Self(
            bridge: bridge,
            historyStore: historyStore,
            trackStore: trackStore,
            directory: directory,
            liveTrack: liveTrack,
            csv: """
            id,name,artist,album,year_before_mgu
            T1,Angel,Massive Attack,Mezzanine,1998
            """
        )
    }

    func coordinator() -> UndoCoordinator {
        UndoCoordinator(
            scriptBridge: bridge,
            changeLogStore: historyStore,
            trackStore: trackStore,
            directory: directory
        )
    }
}

@Suite("Backup CSV recovery transitions")
struct BackupRecoveryTests {
    @Test("No-change mirror retry never creates restore history")
    func mirrorRetrySkipsHistory() async throws {
        let fixture = try await BackupRecoveryFixture.make()
        await fixture.trackStore.failAppliedUpdates()

        await expectRecoveryFailure(effects: ["track mirror"]) {
            _ = try await Self.restore(using: fixture.coordinator(), fixture: fixture)
        }

        await fixture.trackStore.resumeAppliedUpdates()
        let retry = try await Self.restore(using: fixture.coordinator(), fixture: fixture)

        #expect(retry.skippedCount == 1)
        #expect(await fixture.historyStore.entries.isEmpty)
        #expect(try await fixture.trackStore.getTrack(byID: "T1")?.year == 1998)
    }

    @Test("No-change cleanup retry never creates restore history")
    func cleanupRetrySkipsHistory() async throws {
        let fixture = try await BackupRecoveryFixture.make()
        await fixture.trackStore.setAppliedUpdateHook {
            try Self.setPermissions(0o500, on: fixture.directory)
        }
        defer { _ = try? Self.setPermissions(0o700, on: fixture.directory) }

        await expectRecoveryFailure(effects: ["backup recovery checkpoint"]) {
            _ = try await Self.restore(using: fixture.coordinator(), fixture: fixture)
        }

        try Self.setPermissions(0o700, on: fixture.directory)
        await fixture.trackStore.setAppliedUpdateHook(nil)
        let retry = try await Self.restore(using: fixture.coordinator(), fixture: fixture)

        #expect(retry.skippedCount == 1)
        #expect(await fixture.historyStore.entries.isEmpty)
        #expect(try await fixture.trackStore.getTrack(byID: "T1")?.year == 1998)
    }

    @Test("A write error with recovery evidence stops later targets")
    func writeErrorStopsBackupBatch() async {
        let bridge = MockAppleScriptClient()
        await bridge.setWriteError(MockScriptError.intentional, for: "T1")
        let tracks = [
            Track(id: "T1", name: "Angel", artist: "Massive Attack", album: "Mezzanine", year: 2019),
            Track(id: "T2", name: "Teardrop", artist: "Massive Attack", album: "Mezzanine", year: 2020),
        ]
        await bridge.setFetchedTracks(tracks)
        let coordinator = UndoCoordinator(
            scriptBridge: bridge,
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("BackupRecoveryTests-\(UUID().uuidString)")
        )
        let csv = """
        id,name,artist,album,year_before_mgu
        T1,Angel,Massive Attack,Mezzanine,1998
        T2,Teardrop,Massive Attack,Mezzanine,1998
        """

        await expectRecoveryFailure(effects: ["backup recovery checkpoint"]) {
            _ = try await coordinator.revertYearsFromBackupCSV(
                csv,
                artist: "Massive Attack",
                currentTracks: tracks
            )
        }

        #expect(await bridge.writtenProperties.isEmpty)
    }

    private static func restore(
        using coordinator: UndoCoordinator,
        fixture: BackupRecoveryFixture
    ) async throws -> YearBackupRevertResult {
        try await coordinator.revertYearsFromBackupCSV(
            fixture.csv,
            artist: "Massive Attack",
            currentTracks: [fixture.liveTrack]
        )
    }

    private static func setPermissions(_ permissions: Int, on directory: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: directory.path
        )
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
