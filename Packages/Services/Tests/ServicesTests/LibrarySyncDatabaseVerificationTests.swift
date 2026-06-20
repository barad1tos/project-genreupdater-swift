import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("LibrarySyncService — database verification")
struct LibrarySyncDatabaseVerificationTests {
    @Test("Runtime configuration maps legacy temporary logs directory to app support token")
    func runtimeConfigurationMapsLegacyTemporaryLogsDirectory() {
        var configuration = AppConfiguration()
        configuration.paths.logsBaseDirectory = PathsConfig.legacyTemporaryLogsBaseDirectory

        let runtimeConfiguration = LibrarySyncRuntimeConfiguration(configuration: configuration)

        #expect(runtimeConfiguration.logsBaseDirectory == PathsConfig.defaultLogsBaseDirectory)
    }

    @Test("Removes persisted tracks missing from Music.app")
    func removesMissingTracks() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibrarySyncServiceTests-\(UUID().uuidString)")

        await bridge.setLibrary(ids: ["T1", "T3"], tracks: [:])
        await store.setStored([
            Track(id: "T1", name: "One", artist: "Artist", album: "Album"),
            Track(id: "T2", name: "Two", artist: "Artist", album: "Album"),
            Track(id: "T3", name: "Three", artist: "Artist", album: "Album"),
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(
                logsBaseDirectory: logDirectory.path,
                lastDatabaseVerifyLog: "last.log"
            )
        )

        let result = try await service.verifyAndCleanDatabase(force: true)
        let remainingTracks = try await store.loadAllTracks()
        let remainingIDs = remainingTracks.map(\.id).sorted()

        #expect(result.verifiedTrackCount == 3)
        #expect(result.removedTrackIDs == ["T2"])
        #expect(result.removedCount == 1)
        #expect(remainingIDs == ["T1", "T3"])
    }

    @Test("Database verification invalidates cache for removed tracks")
    func databaseVerificationInvalidatesCacheForRemovedTracks() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let cache = MockCacheService()
        let snapshotService = SyncMockLibrarySnapshotService()
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibrarySyncServiceTests-\(UUID().uuidString)")

        await bridge.setLibrary(ids: ["T1"], tracks: [:])
        await store.setStored([
            Track(id: "T1", name: "One", artist: "Artist", album: "Album"),
            Track(id: "T2", name: "Two", artist: "Gone Artist", album: "Gone Album"),
        ])
        await seedSyncCaches(cache, artist: "Gone Artist", album: "Gone Album")

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            cache: cache,
            librarySnapshotService: snapshotService,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(
                logsBaseDirectory: logDirectory.path,
                lastDatabaseVerifyLog: "last.log"
            )
        )

        _ = try await service.verifyAndCleanDatabase(force: true)

        await expectSyncCachesInvalidated(cache, artist: "Gone Artist", album: "Gone Album")
        let wasCleared = await snapshotService.wasCleared()
        #expect(wasCleared)
    }

    @Test("Respects recent timestamp unless forced")
    func skipsRecentRunUnlessForced() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibrarySyncServiceTests-\(UUID().uuidString)")

        await bridge.setLibrary(ids: ["T1"], tracks: [:])
        await store.setStored([
            Track(id: "T1", name: "One", artist: "Artist", album: "Album"),
            Track(id: "T2", name: "Two", artist: "Artist", album: "Album"),
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(
                databaseVerificationIntervalDays: 7,
                logsBaseDirectory: logDirectory.path,
                lastDatabaseVerifyLog: "last.log"
            )
        )

        _ = try await service.verifyAndCleanDatabase(force: true)

        await store.setStored([
            Track(id: "T1", name: "One", artist: "Artist", album: "Album"),
            Track(id: "T3", name: "Three", artist: "Artist", album: "Album"),
        ])

        let skipped = try await service.verifyAndCleanDatabase()
        let afterSkipTracks = try await store.loadAllTracks()
        let afterSkipIDs = afterSkipTracks.map(\.id).sorted()

        #expect(skipped.skippedDueToRecentVerification)
        #expect(afterSkipIDs == ["T1", "T3"])

        let forced = try await service.verifyAndCleanDatabase(force: true)
        let afterForceTracks = try await store.loadAllTracks()
        let afterForceIDs = afterForceTracks.map(\.id).sorted()

        #expect(!forced.skippedDueToRecentVerification)
        #expect(forced.removedTrackIDs == ["T3"])
        #expect(afterForceIDs == ["T1"])
    }
}
