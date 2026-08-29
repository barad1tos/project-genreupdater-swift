import Foundation
import SwiftData
import Testing
@testable import Core
@testable import Services

@Suite("LibrarySyncService — database verification")
struct LibrarySyncVerifyTests {
    @Test("Runtime configuration maps legacy temporary logs directory to app support token")
    func runtimeConfigurationMapsLegacyTemporaryLogsDirectory() throws {
        var configuration = AppConfiguration()
        configuration.paths.logsBaseDirectory = PathsConfig.legacyTemporaryLogsBaseDirectory

        let runtimeConfiguration = try LibrarySyncRuntimeConfiguration(configuration: configuration)

        #expect(runtimeConfiguration.logsBaseDirectory == PathsConfig.defaultLogsBaseDirectory)
    }

    @Test("Removes persisted tracks missing from Music.app")
    func removesMissingTracks() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibrarySyncServiceTests-\(UUID().uuidString)")

        await bridge.setLibrary(ids: ["T1", "T3"], tracks: [:])
        await store.setStored([
            Track(id: "T1", name: "One", artist: "Artist", album: "Album"),
            Track(id: "T2", name: "Two", artist: "Artist", album: "Album"),
            Track(id: "T3", name: "Three", artist: "Artist", album: "Album"),
        ])

        let service = LibrarySyncService(
            trackStore: store,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(
                logsBaseDirectory: logDirectory.path,
                lastDatabaseVerifyLog: "last.log"
            ),
            observer: bridge
        )

        let result = try await service.verifyAndCleanDatabase(force: true)
        let remainingTracks = try await store.loadAllTracks()
        let remainingIDs = remainingTracks.map(\.id).sorted()

        #expect(result.verifiedTrackCount == 3)
        #expect(result.removedTrackIDs == ["T2"])
        #expect(result.removedCount == 1)
        #expect(remainingIDs == ["T1", "T3"])
    }

    @Test("Database verification re-observes after a mirror revision conflict")
    func verificationReobserves() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibrarySyncServiceTests-\(UUID().uuidString)")

        await bridge.setLibrary(ids: ["T1"], tracks: [:])
        await store.setStored([
            Track(id: "T1", name: "One", artist: "Artist", album: "Album"),
            Track(id: "T2", name: "Two", artist: "Artist", album: "Album"),
        ])
        await store.rejectNextMirrorCommits()
        let service = LibrarySyncService(
            trackStore: store,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(
                logsBaseDirectory: logDirectory.path,
                lastDatabaseVerifyLog: "last.log",
                mirrorRetryPolicy: MirrorRetryPolicy(retryLimit: 1, delay: .zero)
            ),
            observer: bridge
        )

        let result = try await service.verifyAndCleanDatabase(force: true)

        #expect(result.removedTrackIDs == ["T2"])
        #expect(await bridge.recordedObservationRequests().count == 2)
        #expect(try await store.loadAllTracks().map(\.id) == ["T1"])
    }

    @Test("No-op database verification preserves scoped processing readiness")
    func keepsNoOpReady() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibrarySyncNoOp-\(UUID().uuidString)")
        let track = Track(
            id: "T1",
            name: "One",
            artist: "Target",
            album: "Album",
            appleScriptID: "T1"
        )
        await bridge.setLibrary(ids: ["T1"], tracks: [:])
        await store.setInventory([track])
        await store.setScopeCertificate(testArtists: ["Target"])
        let service = LibrarySyncService(
            trackStore: store,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(
                logsBaseDirectory: logDirectory.path,
                lastDatabaseVerifyLog: "last.log",
                testArtists: ["Target"]
            ),
            observer: bridge
        )

        #expect(try await store.readiness(testArtists: ["Target"]).isReady)

        _ = try await service.verifyAndCleanDatabase(force: true)

        let snapshot = try await store.loadMirrorSnapshot()
        #expect(snapshot.revision == MirrorRevision(value: 1))
        #expect(try await store.readiness(testArtists: ["Target"]).isReady)
    }

    @Test("Maintenance records its commit without promoting a certificate")
    func maintenanceKeepsCertificate() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = TrackDataStore(modelContainer: container)
        try await store.initialize()
        let bridge = SyncMockScriptClient()
        let track = Track(id: "T1", name: "One", artist: "Target", album: "Album")
        await bridge.setLibrary(ids: ["T1"], tracks: ["T1": track])
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibrarySyncMaintenance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        let service = LibrarySyncService(
            trackStore: store,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(
                logsBaseDirectory: logDirectory.path,
                lastDatabaseVerifyLog: "last.log"
            ),
            observer: bridge
        )
        _ = try await service.synchronizeNow(forceMetadataRefresh: true)
        let before = try await store.loadMirrorSnapshot()
        let certificate = try #require(before.certificates.first)

        _ = try await service.verifyAndCleanDatabase(force: true)

        let after = try await store.loadMirrorSnapshot()
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<PersistedSyncRecord>())
        #expect(after.certificates.map(\.id) == [certificate.id])
        #expect(after.revision == MirrorRevision(value: 2))
        #expect(records.count == 2)
        #expect(records.contains { $0.modeRaw == "membershipOnly" && $0.certificateID == nil })
    }

    @Test("Database verification persists identity facts without a membership delta")
    func verificationPersistsIdentityWithoutMembershipDelta() async throws {
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let bridge = SyncMockScriptClient(observedAt: { observedAt })
        let store = try TrackDataStore.createInMemory()
        let databaseID = testDatabaseID("T1")
        let track = Track(
            id: databaseID.rawValue,
            name: "One",
            artist: "Target",
            album: "Album",
            appleScriptID: databaseID.rawValue
        )
        let membership = try MembershipFingerprint.make(ids: [databaseID])
        _ = try await store.commitMirror(MirrorCommit(
            baseRevision: .initial,
            inventoryChange: .replace(
                stamp: membership,
                ids: [databaseID],
                identities: [],
                observedAt: observedAt
            ),
            repairs: [],
            upserts: [track],
            certificates: .invalidate(.incompleteObservation)
        ))
        await bridge.setLibrary(ids: [databaseID.rawValue], tracks: [databaseID.rawValue: track])
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibrarySyncIdentity-\(UUID().uuidString)")
        let service = LibrarySyncService(
            trackStore: store,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(
                logsBaseDirectory: logDirectory.path,
                lastDatabaseVerifyLog: "last.log",
                testArtists: ["Target"]
            ),
            observer: bridge
        )

        _ = try await service.verifyAndCleanDatabase(force: true)

        let snapshot = try await store.loadMirrorSnapshot()
        #expect(snapshot.memberIdentities[databaseID]?.artist == "Target")
        #expect(snapshot.memberIdentities[databaseID]?.albumArtist == nil)
        #expect(snapshot.memberIdentities[databaseID]?.observedAt == observedAt)
    }

    @Test("Database verification stops after the configured conflict retries")
    func verificationRetryLimit() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let cache = MockCacheService()
        let snapshotService = SyncMockLibrarySnapshotService()
        let pending = PendingVerificationProbe(
            entry: PendingAlbumEntry(
                id: "gone-album",
                artist: "Gone Artist",
                album: "Gone Album",
                reason: "prerelease"
            ),
            isVerificationNeeded: true
        )
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibrarySyncRetryLimit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: logDirectory) }

        await bridge.setLibrary(ids: ["T1"], tracks: [:])
        await store.setStored([
            Track(id: "T1", name: "One", artist: "Artist", album: "Album"),
            Track(id: "T2", name: "Gone", artist: "Gone Artist", album: "Gone Album"),
        ])
        await seedSyncCaches(cache, artist: "Gone Artist", album: "Gone Album")
        await store.rejectNextMirrorCommits(2)
        let service = LibrarySyncService(
            trackStore: store,
            cache: cache,
            pendingVerificationService: pending,
            librarySnapshotService: snapshotService,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(
                logsBaseDirectory: logDirectory.path,
                lastDatabaseVerifyLog: "last.log",
                mirrorRetryPolicy: MirrorRetryPolicy(retryLimit: 1, delay: .zero)
            ),
            observer: bridge
        )

        await #expect(throws: MirrorRevisionConflict(
            expected: MirrorRevision(value: 1),
            actual: MirrorRevision(value: 2)
        )) {
            try await service.verifyAndCleanDatabase(force: true)
        }

        #expect(await bridge.recordedObservationRequests().count == 2)
        #expect(try await store.loadAllTracks().map(\.id).sorted() == ["T1", "T2"])
        #expect(await (pending.removedAlbums).isEmpty)
        #expect(await !(snapshotService.wasCleared()))
        await expectSyncCachesPreserved(cache, artist: "Gone Artist", album: "Gone Album")
        #expect(!FileManager.default.fileExists(atPath: logDirectory.appendingPathComponent("last.log").path))
    }

    @Test("Database verification invalidates cache for removed tracks")
    func databaseVerificationInvalidatesCacheForRemovedTracks() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
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
            trackStore: store,
            cache: cache,
            librarySnapshotService: snapshotService,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(
                logsBaseDirectory: logDirectory.path,
                lastDatabaseVerifyLog: "last.log"
            ),
            observer: bridge
        )

        _ = try await service.verifyAndCleanDatabase(force: true)

        await expectSyncCachesInvalidated(cache, artist: "Gone Artist", album: "Gone Album")
        let wasCleared = await snapshotService.wasCleared()
        #expect(wasCleared)
    }

    @Test(
        "Database verification removes pending prerelease row when the album disappears",
        arguments: [
            TrackKind.prerelease.rawValue,
            nil,
        ] as [String?]
    )
    func databaseVerificationRemovesPendingPrereleaseRowWhenAlbumDisappears(trackStatus: String?) async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let pending = PendingVerificationProbe(
            entry: PendingAlbumEntry(
                id: "pending-prerelease",
                artist: "Gone Artist",
                album: "Future Album",
                reason: "prerelease"
            ),
            isVerificationNeeded: true
        )
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibrarySyncServiceTests-\(UUID().uuidString)")

        await bridge.setLibrary(ids: ["T1"], tracks: [:])
        await store.setStored([
            Track(id: "T1", name: "One", artist: "Artist", album: "Album"),
            Track(
                id: "T2",
                name: "Future Track",
                artist: "Gone Artist",
                album: "Future Album",
                trackStatus: trackStatus
            ),
        ])

        let service = LibrarySyncService(
            trackStore: store,
            pendingVerificationService: pending,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(
                logsBaseDirectory: logDirectory.path,
                lastDatabaseVerifyLog: "last.log"
            ),
            observer: bridge
        )

        _ = try await service.verifyAndCleanDatabase(force: true)

        let removedAlbums = await pending.removedAlbums
        #expect(removedAlbums.map(\.album) == ["Future Album"])
    }

    @Test("Respects recent timestamp unless forced")
    func skipsRecentRunUnlessForced() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibrarySyncServiceTests-\(UUID().uuidString)")

        await bridge.setLibrary(ids: ["T1"], tracks: [:])
        await store.setStored([
            Track(id: "T1", name: "One", artist: "Artist", album: "Album"),
            Track(id: "T2", name: "Two", artist: "Artist", album: "Album"),
        ])

        let service = LibrarySyncService(
            trackStore: store,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(
                databaseVerificationIntervalDays: 7,
                logsBaseDirectory: logDirectory.path,
                lastDatabaseVerifyLog: "last.log"
            ),
            observer: bridge
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

    @Test("Disabled automatic schedule keeps forced verification available")
    func disabledScheduleAllowsForcedVerification() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibrarySyncServiceTests-\(UUID().uuidString)")
        await bridge.setLibrary(ids: ["T1"], tracks: [:])
        await store.setStored([
            Track(id: "T1", name: "One", artist: "Artist", album: "Album"),
            Track(id: "T2", name: "Two", artist: "Artist", album: "Album"),
        ])
        let service = LibrarySyncService(
            trackStore: store,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(
                databaseVerificationIntervalDays: 0,
                logsBaseDirectory: logDirectory.path,
                lastDatabaseVerifyLog: "last.log"
            ),
            observer: bridge
        )

        let scheduledResult = try await service.runScheduledVerification()

        #expect(scheduledResult == nil)
        #expect(await bridge.recordedObservationRequests().isEmpty)

        let result = try await service.verifyAndCleanDatabase(force: true)

        #expect(result.removedTrackIDs == ["T2"])
        let requests = await bridge.recordedObservationRequests()
        #expect(requests.count == 1)
        #expect(requests.first?.refresh == .membershipOnly)
    }
}
