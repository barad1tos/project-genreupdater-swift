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

    static func make(liveYear: Int = 1998) async throws -> Self {
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
        liveTrack.year = liveYear
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
            stores: .init(changeLog: historyStore, tracks: trackStore),
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

    @Test("Pre-dispatch cancellation remains safe to retry")
    func cancellationRetry() async throws {
        let fixture = try await BackupRecoveryFixture.make(liveYear: 2019)
        await fixture.bridge.setWriteCancellationMode(true)

        do {
            _ = try await Self.restore(using: fixture.coordinator(), fixture: fixture)
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected: the bridge never reported an attempted write.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        await fixture.bridge.setWriteCancellationMode(false)
        let retry = try await Self.restore(using: fixture.coordinator(), fixture: fixture)

        #expect(retry.updatedCount == 1)
        #expect(retry.skippedCount == 0)
        #expect(await fixture.bridge.writtenProperties.count == 1)
        let history = await fixture.historyStore.entries
        #expect(history.count == 1)
        #expect(history.first?.oldYear == 2019)
        #expect(history.first?.newYear == 1998)
        #expect(try await fixture.trackStore.getTrack(byID: "T1")?.year == 1998)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("pending-year-revert.json").path
        ))
    }

    @Test("Failed no-change phase persistence blocks automatic retry")
    func noChangePhaseFailureBlocksRetry() async throws {
        let fixture = try await BackupRecoveryFixture.make()
        let checkpoint = fixture.directory.appendingPathComponent("pending-year-revert.json")
        await fixture.bridge.setWriteAttemptHook {
            try Self.setImmutable(true, on: checkpoint)
        }
        defer { _ = try? Self.setImmutable(false, on: checkpoint) }

        await expectRecoveryFailure(effects: ["backup recovery checkpoint"]) {
            _ = try await Self.restore(using: fixture.coordinator(), fixture: fixture)
        }

        try Self.setImmutable(false, on: checkpoint)
        await fixture.bridge.setWriteAttemptHook(nil)
        await expectRecoveryFailure(effects: ["ambiguous backup write outcome"]) {
            _ = try await Self.restore(using: fixture.coordinator(), fixture: fixture)
        }
        #expect(await fixture.historyStore.entries.isEmpty)
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

        await bridge.setWriteError(nil, for: "T1")
        await expectRecoveryFailure(effects: ["ambiguous backup write outcome"]) {
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

    private static func setImmutable(_ isImmutable: Bool, on file: URL) throws {
        try FileManager.default.setAttributes(
            [.immutable: isImmutable],
            ofItemAtPath: file.path
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
