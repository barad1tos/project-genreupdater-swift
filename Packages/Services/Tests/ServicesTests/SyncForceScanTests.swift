import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("LibrarySyncService — force scan scheduling")
struct SyncForceScanTests {
    private static let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Fast mode skips metadata fetch for common tracks")
    func fastModeSkipsMetadataFetchForCommonTracks() async throws {
        let fixture = await Self.makeFixture()

        let result = try await fixture.service.detectChanges()

        #expect(!result.hasChanges)
        #expect(await fixture.bridge.fetchTracksRequestCount() == 0)
    }

    @Test("Force mode fetches common tracks and records force scan timestamp")
    func forceModeFetchesCommonTracksAndRecordsTimestamp() async throws {
        let scanDate = Self.baseDate
        let oldDate = scanDate.addingTimeInterval(-3600)
        let fixture = await Self.makeFixture(
            now: scanDate,
            stored: Self.track(name: "Stored", lastModified: oldDate),
            current: Self.track(name: "Changed", lastModified: scanDate),
            metadata: Self.metadata(timestamp: oldDate)
        )

        let result = try await fixture.service.detectChanges(forceMetadataRefresh: true)
        let metadata = await fixture.snapshotService.getSnapshotMetadata()

        #expect(result.modifiedTracks.map(\.id) == ["T1"])
        #expect(await fixture.bridge.fetchedTrackIDSets() == [Set(["T1"])])
        #expect(metadata?.lastForceScanDate == scanDate)
    }

    @Test("Stale force scan timestamp triggers metadata refresh")
    func staleForceScanTimestampTriggersMetadataRefresh() async throws {
        let now = Self.baseDate
        let staleForceScanDate = now.addingTimeInterval(-8 * 86400)
        let fixture = await Self.makeFixture(
            now: now,
            metadata: Self.metadata(
                timestamp: staleForceScanDate,
                lastForceScanDate: staleForceScanDate
            )
        )

        let result = try await fixture.service.detectChanges()
        let metadata = await fixture.snapshotService.getSnapshotMetadata()

        #expect(result.modifiedTracks.map(\.id) == ["T1"])
        #expect(await fixture.bridge.fetchTracksRequestCount() == 1)
        #expect(metadata?.lastForceScanDate == now)
    }

    @Test("Missing force scan timestamp stays in fast mode")
    func missingForceScanTimestampStaysInFastMode() async throws {
        let now = Self.baseDate
        let fixture = await Self.makeFixture(
            now: now,
            metadata: Self.metadata(timestamp: now.addingTimeInterval(-3600))
        )

        let result = try await fixture.service.detectChanges()
        let metadata = await fixture.snapshotService.getSnapshotMetadata()

        #expect(!result.hasChanges)
        #expect(await fixture.bridge.fetchTracksRequestCount() == 0)
        #expect(metadata?.lastForceScanDate == now)
    }

    @Test("Seeded force scan timestamp allows later scheduled metadata refresh")
    func seededForceScanTimestampAllowsLaterScheduledMetadataRefresh() async throws {
        let firstSyncDate = Self.baseDate
        let secondSyncDate = firstSyncDate.addingTimeInterval(8 * 86400)
        let dateProvider = SyncDateProvider(firstSyncDate)
        let fixture = await Self.makeFixture(
            metadata: Self.metadata(timestamp: firstSyncDate.addingTimeInterval(-3600)),
            currentDate: dateProvider.now
        )

        let firstResult = try await fixture.service.detectChanges()
        dateProvider.set(secondSyncDate)
        let secondResult = try await fixture.service.detectChanges()
        let metadata = await fixture.snapshotService.getSnapshotMetadata()

        #expect(!firstResult.hasChanges)
        #expect(secondResult.modifiedTracks.map(\.id) == ["T1"])
        #expect(await fixture.bridge.fetchTracksRequestCount() == 1)
        #expect(metadata?.lastForceScanDate == secondSyncDate)
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
        let gate = await FeatureGate(fixedTier: .free)
        let snapshotService = SyncMockLibrarySnapshotService()
        let dateProvider: @Sendable () -> Date = if let currentDate {
            currentDate
        } else {
            { now }
        }

        await bridge.setLibrary(ids: ["T1"], tracks: ["T1": current])
        await store.setStored([stored])
        if let metadata {
            await snapshotService.setMetadata(metadata)
        }

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            librarySnapshotService: snapshotService,
            currentDate: dateProvider
        )
        return ForceScanFixture(
            bridge: bridge,
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
    let snapshotService: SyncMockLibrarySnapshotService
    let service: LibrarySyncService
}
