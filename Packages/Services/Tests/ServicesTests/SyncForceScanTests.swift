import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("LibrarySyncService — force scan scheduling")
struct SyncForceScanTests {
    @Test("Fast mode skips metadata fetch for common tracks")
    func fastModeSkipsMetadataFetchForCommonTracks() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)

        let stored = Track(id: "T1", name: "Stored", artist: "A", album: "B")
        let current = Track(id: "T1", name: "Changed", artist: "A", album: "B")
        await bridge.setLibrary(ids: ["T1"], tracks: ["T1": current])
        await store.setStored([stored])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate
        )

        let result = try await service.detectChanges()

        #expect(!result.hasChanges)
        #expect(await bridge.fetchTracksRequestCount() == 0)
    }

    @Test("Force mode fetches common tracks and records force scan timestamp")
    func forceModeFetchesCommonTracksAndRecordsTimestamp() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let snapshotService = SyncMockLibrarySnapshotService()
        let scanDate = Date(timeIntervalSince1970: 1_800_000_000)

        let oldDate = scanDate.addingTimeInterval(-3600)
        let stored = Track(id: "T1", name: "Stored", artist: "A", album: "B", lastModified: oldDate)
        let current = Track(id: "T1", name: "Changed", artist: "A", album: "B", lastModified: scanDate)
        await bridge.setLibrary(ids: ["T1"], tracks: ["T1": current])
        await store.setStored([stored])
        await snapshotService.setMetadata(LibraryCacheMetadata(
            trackCount: 1,
            snapshotHash: "hash",
            timestamp: oldDate,
            libraryModificationDate: oldDate
        ))

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            librarySnapshotService: snapshotService,
            currentDate: { scanDate }
        )

        let result = try await service.detectChanges(forceMetadataRefresh: true)
        let metadata = await snapshotService.getSnapshotMetadata()

        #expect(result.modifiedTracks.map(\.id) == ["T1"])
        #expect(await bridge.fetchedTrackIDSets() == [Set(["T1"])])
        #expect(metadata?.lastForceScanDate == scanDate)
    }

    @Test("Stale force scan timestamp triggers metadata refresh")
    func staleForceScanTimestampTriggersMetadataRefresh() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let snapshotService = SyncMockLibrarySnapshotService()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let staleForceScanDate = now.addingTimeInterval(-8 * 86400)

        let stored = Track(id: "T1", name: "Stored", artist: "A", album: "B")
        let current = Track(id: "T1", name: "Changed", artist: "A", album: "B")
        await bridge.setLibrary(ids: ["T1"], tracks: ["T1": current])
        await store.setStored([stored])
        await snapshotService.setMetadata(LibraryCacheMetadata(
            trackCount: 1,
            snapshotHash: "hash",
            timestamp: staleForceScanDate,
            libraryModificationDate: staleForceScanDate,
            lastForceScanDate: staleForceScanDate
        ))

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            librarySnapshotService: snapshotService,
            currentDate: { now }
        )

        let result = try await service.detectChanges()
        let metadata = await snapshotService.getSnapshotMetadata()

        #expect(result.modifiedTracks.map(\.id) == ["T1"])
        #expect(await bridge.fetchTracksRequestCount() == 1)
        #expect(metadata?.lastForceScanDate == now)
    }

    @Test("Missing force scan timestamp stays in fast mode")
    func missingForceScanTimestampStaysInFastMode() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let snapshotService = SyncMockLibrarySnapshotService()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshotDate = now.addingTimeInterval(-3600)

        let stored = Track(id: "T1", name: "Stored", artist: "A", album: "B")
        let current = Track(id: "T1", name: "Changed", artist: "A", album: "B")
        await bridge.setLibrary(ids: ["T1"], tracks: ["T1": current])
        await store.setStored([stored])
        await snapshotService.setMetadata(LibraryCacheMetadata(
            trackCount: 1,
            snapshotHash: "hash",
            timestamp: snapshotDate,
            libraryModificationDate: snapshotDate
        ))

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            librarySnapshotService: snapshotService,
            currentDate: { now }
        )

        let result = try await service.detectChanges()
        let metadata = await snapshotService.getSnapshotMetadata()

        #expect(!result.hasChanges)
        #expect(await bridge.fetchTracksRequestCount() == 0)
        #expect(metadata?.lastForceScanDate == now)
    }

    @Test("Seeded force scan timestamp allows later scheduled metadata refresh")
    func seededForceScanTimestampAllowsLaterScheduledMetadataRefresh() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let snapshotService = SyncMockLibrarySnapshotService()
        let firstSyncDate = Date(timeIntervalSince1970: 1_800_000_000)
        let secondSyncDate = firstSyncDate.addingTimeInterval(8 * 86400)
        let snapshotDate = firstSyncDate.addingTimeInterval(-3600)

        let stored = Track(id: "T1", name: "Stored", artist: "A", album: "B")
        let current = Track(id: "T1", name: "Changed", artist: "A", album: "B")
        await bridge.setLibrary(ids: ["T1"], tracks: ["T1": current])
        await store.setStored([stored])
        await snapshotService.setMetadata(LibraryCacheMetadata(
            trackCount: 1,
            snapshotHash: "hash",
            timestamp: snapshotDate,
            libraryModificationDate: snapshotDate
        ))
        let dateProvider = SyncDateProvider(firstSyncDate)

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            librarySnapshotService: snapshotService,
            currentDate: dateProvider.now
        )

        let firstResult = try await service.detectChanges()
        dateProvider.set(secondSyncDate)
        let secondResult = try await service.detectChanges()
        let metadata = await snapshotService.getSnapshotMetadata()

        #expect(!firstResult.hasChanges)
        #expect(secondResult.modifiedTracks.map(\.id) == ["T1"])
        #expect(await bridge.fetchTracksRequestCount() == 1)
        #expect(metadata?.lastForceScanDate == secondSyncDate)
    }
}
