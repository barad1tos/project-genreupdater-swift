import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("LibrarySyncService — force scan scheduling")
struct SyncForceScanTests {
    private static let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Fast mode skips metadata fetch for common tracks")
    func usesFastObservationForCommonTracks() async throws {
        let fixture = await Self.makeFixture()

        let result = try await fixture.service.detectObservation().result
        let requests = await fixture.bridge.recordedObservationRequests()

        #expect(!result.hasChanges)
        #expect(requests.map(\.refresh) == [.fast])
    }

    @Test("Force sync commits metadata and records force scan timestamp")
    func commitsForcedRefresh() async throws {
        let scanDate = Self.baseDate
        let oldDate = scanDate.addingTimeInterval(-3600)
        let fixture = await Self.makeFixture(
            now: scanDate,
            stored: Self.track(name: "Stored", lastModified: oldDate),
            current: Self.track(name: "Changed", lastModified: scanDate),
            metadata: Self.metadata(timestamp: oldDate)
        )

        let result = try await fixture.service.synchronizeNow(forceMetadataRefresh: true)
        let requests = await fixture.bridge.recordedObservationRequests()
        let metadata = await fixture.snapshotService.getSnapshotMetadata()
        let persisted = try #require(await fixture.store.getTrack(byID: "T1"))

        #expect(result.modifiedTracks.map(\.id) == ["T1"])
        #expect(requests.map(\.refresh) == [.force])
        #expect(persisted.genre == "Changed")
        #expect(metadata?.lastForceScanDate == scanDate)
    }

    @Test("Stale timestamp triggers a committed metadata refresh")
    func refreshesStaleMetadata() async throws {
        let now = Self.baseDate
        let staleForceScanDate = now.addingTimeInterval(-8 * 86400)
        let fixture = await Self.makeFixture(
            now: now,
            metadata: Self.metadata(
                timestamp: staleForceScanDate,
                lastForceScanDate: staleForceScanDate
            )
        )

        let result = try await fixture.service.synchronizeNow()
        let requests = await fixture.bridge.recordedObservationRequests()
        let metadata = await fixture.snapshotService.getSnapshotMetadata()

        #expect(result.modifiedTracks.map(\.id) == ["T1"])
        #expect(requests.map(\.refresh) == [.force])
        #expect(metadata?.lastForceScanDate == now)
    }

    @Test("Missing force scan timestamp stays in fast mode")
    func keepsUnseededScanFast() async throws {
        let now = Self.baseDate
        let fixture = await Self.makeFixture(
            now: now,
            metadata: Self.metadata(timestamp: now.addingTimeInterval(-3600))
        )

        let result = try await fixture.service.detectObservation().result
        let requests = await fixture.bridge.recordedObservationRequests()
        let metadata = await fixture.snapshotService.getSnapshotMetadata()

        #expect(!result.hasChanges)
        #expect(requests.map(\.refresh) == [.fast])
        #expect(metadata?.lastForceScanDate == nil)
    }

    @Test("Completed force scan enables later scheduled metadata refresh")
    func enablesScheduledRefresh() async throws {
        let firstSyncDate = Self.baseDate
        let secondSyncDate = firstSyncDate.addingTimeInterval(8 * 86400)
        let dateProvider = SyncDateProvider(firstSyncDate)
        let fixture = await Self.makeFixture(
            metadata: Self.metadata(timestamp: firstSyncDate.addingTimeInterval(-3600)),
            currentDate: dateProvider.now
        )

        let firstResult = try await fixture.service.synchronizeNow(forceMetadataRefresh: true)
        dateProvider.set(secondSyncDate)
        await fixture.bridge.setLibrary(
            ids: ["T1"],
            tracks: ["T1": Self.track(name: "Changed Again")]
        )
        let secondResult = try await fixture.service.synchronizeNow()
        let requests = await fixture.bridge.recordedObservationRequests()
        let metadata = await fixture.snapshotService.getSnapshotMetadata()
        let persisted = try #require(await fixture.store.getTrack(byID: "T1"))

        #expect(firstResult.modifiedTracks.map(\.id) == ["T1"])
        #expect(secondResult.modifiedTracks.map(\.id) == ["T1"])
        #expect(requests.map(\.refresh) == [.force, .force])
        #expect(persisted.genre == "Changed Again")
        #expect(metadata?.lastForceScanDate == secondSyncDate)
    }

    @Test("Snapshot refresh does not postpone a weekly metadata scan")
    func refreshKeepsScanDue() async throws {
        let forceScanDate = Self.baseDate
        let refreshDate = forceScanDate.addingTimeInterval(8 * 86400)
        let dateProvider = SyncDateProvider(forceScanDate)
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        let uiSnapshotService = CachedLibrarySnapshotService(
            cache: cache,
            configuration: LibrarySnapshotConfig(),
            currentDate: dateProvider.now
        )
        let storedTrack = Self.track(name: "Metal")
        _ = try await uiSnapshotService.saveSnapshot([storedTrack])
        var metadata = try #require(await uiSnapshotService.getSnapshotMetadata())
        metadata.lastForceScanDate = forceScanDate
        try await uiSnapshotService.updateSnapshotMetadata(metadata)

        dateProvider.set(refreshDate)
        _ = try await uiSnapshotService.saveSnapshot([storedTrack])

        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        await bridge.setLibrary(ids: ["T1"], tracks: ["T1": Self.track(name: "Alternative")])
        await store.setStored([storedTrack])
        let syncSnapshotService = CachedLibrarySnapshotService(
            cache: cache,
            configuration: LibrarySnapshotConfig(),
            currentDate: dateProvider.now
        )
        let service = LibrarySyncService(
            trackStore: store,
            librarySnapshotService: syncSnapshotService,
            currentDate: dateProvider.now,
            observer: bridge
        )

        let result = try await service.synchronizeNow()
        let requests = await bridge.recordedObservationRequests()
        let metadataAfterSync = await syncSnapshotService.getSnapshotMetadata()
        let persisted = try #require(await store.getTrack(byID: "T1"))

        #expect(result.modifiedTracks.map(\.id) == ["T1"])
        #expect(requests.map(\.refresh) == [.force])
        #expect(persisted.genre == "Alternative")
        #expect(metadataAfterSync?.lastForceScanDate == refreshDate)
    }

    private static func makeFixture(
        now: Date = baseDate,
        stored: Track = track(name: "Stored"),
        current: Track = track(name: "Changed"),
        metadata: LibraryCacheMetadata? = nil,
        currentDate: (@Sendable () -> Date)? = nil
    ) async -> ForceScanFixture {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let snapshotService = SyncMockLibrarySnapshotService()
        let dateProvider: @Sendable () -> Date = if let currentDate {
            currentDate
        } else {
            { now }
        }

        await bridge.setLibrary(ids: ["T1"], tracks: ["T1": current])
        await store.setStored([stored], certificateDate: now)
        if let metadata {
            await snapshotService.setMetadata(metadata)
        }

        let service = LibrarySyncService(
            trackStore: store,
            librarySnapshotService: snapshotService,
            currentDate: dateProvider,
            observer: bridge
        )
        return ForceScanFixture(
            bridge: bridge,
            store: store,
            snapshotService: snapshotService,
            service: service
        )
    }

    private static func track(name: String, lastModified: Date? = nil) -> Track {
        Track(
            id: "T1",
            name: "Song",
            artist: "A",
            album: "B",
            genre: name,
            lastModified: lastModified
        )
    }

    private static func metadata(
        timestamp: Date,
        lastForceScanDate: Date? = nil
    ) -> LibraryCacheMetadata {
        LibraryCacheMetadata(
            trackCount: 1,
            snapshotHash: "hash",
            timestamp: timestamp,
            libraryModificationDate: timestamp,
            lastForceScanDate: lastForceScanDate
        )
    }
}

private struct ForceScanFixture {
    let bridge: SyncMockScriptClient
    let store: SyncMockTrackStore
    let snapshotService: SyncMockLibrarySnapshotService
    let service: LibrarySyncService
}
