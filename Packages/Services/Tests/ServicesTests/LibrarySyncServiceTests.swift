import Foundation
import Testing
@testable import Core
@testable import Services

// MARK: - Configurable Mock Script Client

actor SyncMockScriptClient: AppleScriptClient {
    var libraryTrackIDs: [String] = []
    var tracksByID: [String: Track] = [:]
    private var fetchTracksRequests: [(trackIDs: [String], batchSize: Int, timeout: Duration?)] = []
    private var fetchAllTrackIDsTimeouts: [Duration?] = []

    func initialize() async throws {}

    func runScript(
        name: String,
        arguments: [String],
        timeout: Duration?
    ) async throws -> String? {
        nil
    }

    func fetchTracksByIDs(
        _ trackIDs: [String],
        batchSize: Int,
        timeout: Duration?
    ) async throws -> [Track] {
        fetchTracksRequests.append((trackIDs: trackIDs, batchSize: batchSize, timeout: timeout))
        return trackIDs.compactMap { tracksByID[$0] }
    }

    func fetchAllTrackIDs(timeout: Duration?) async throws -> [String] {
        fetchAllTrackIDsTimeouts.append(timeout)
        return libraryTrackIDs
    }

    func updateTrackProperty(trackID: String, property: String, value: String) async throws {}

    func lastFetchTracksRequest() -> (batchSize: Int, timeout: Duration?)? {
        guard let request = fetchTracksRequests.last else { return nil }
        return (batchSize: request.batchSize, timeout: request.timeout)
    }

    func fetchTracksRequestCount() -> Int {
        fetchTracksRequests.count
    }

    func fetchedTrackIDSets() -> [Set<String>] {
        fetchTracksRequests.map { Set($0.trackIDs) }
    }

    func lastFetchAllTrackIDsTimeout() -> Duration? {
        guard let timeout = fetchAllTrackIDsTimeouts.last else { return nil }
        return timeout
    }
}

// MARK: - Configurable Mock Track Store

actor SyncMockTrackStore: TrackStateStore {
    var storedTracks: [Track] = []

    func initialize() async throws {}

    func loadAllTracks() async throws -> [Track] {
        storedTracks
    }

    func saveTracks(_ tracks: [Track]) async throws {
        for track in tracks {
            if let index = storedTracks.firstIndex(where: { $0.id == track.id }) {
                storedTracks[index] = track
            } else {
                storedTracks.append(track)
            }
        }
    }

    func deleteTrackIDs(_ ids: [String]) async throws -> Int {
        let idsToDelete = Set(ids)
        let originalCount = storedTracks.count
        storedTracks.removeAll { idsToDelete.contains($0.id) }
        return originalCount - storedTracks.count
    }

    func getTrack(byID id: String) async throws -> Track? {
        storedTracks.first { $0.id == id }
    }

    func updateTrackProcessingState(
        id: String,
        genreUpdated: Bool?,
        yearUpdated: Bool?
    ) async throws {}

    func getUnprocessedTracks() async throws -> [Track] {
        storedTracks
    }

    func trackCount() async throws -> Int {
        storedTracks.count
    }
}

// MARK: - Tests

@Suite("LibrarySyncService — library change detection")
struct LibrarySyncServiceTests {
    @Test("Detect new tracks in library")
    func detectNewTracks() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)

        let newTrack = Track(id: "NEW1", name: "New Song", artist: "Artist", album: "Album")
        await bridge.setLibrary(ids: ["T1", "NEW1"], tracks: [
            "T1": Track(id: "T1", name: "Existing", artist: "A", album: "B"),
            "NEW1": newTrack,
        ])
        await store.setStored([
            Track(id: "T1", name: "Existing", artist: "A", album: "B"),
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate
        )

        let result = try await service.detectChanges()
        #expect(result.newTracks.count == 1)
        #expect(result.newTracks.first?.id == "NEW1")
        #expect(result.removedTrackIDs.isEmpty)
    }

    @Test("Uses configured AppleScript batch and timeout values")
    func usesConfiguredAppleScriptBatchAndTimeoutValues() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)

        let newTrack = Track(id: "NEW1", name: "New Song", artist: "Artist", album: "Album")
        await bridge.setLibrary(ids: ["NEW1"], tracks: ["NEW1": newTrack])
        await store.setStored([])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(
                idsBatchSize: 7,
                fullLibraryFetchTimeout: .seconds(11),
                idsBatchFetchTimeout: .seconds(13)
            )
        )

        _ = try await service.detectChanges()

        let fetchRequest = await bridge.lastFetchTracksRequest()
        #expect(await bridge.lastFetchAllTrackIDsTimeout() == .seconds(11))
        #expect(fetchRequest?.batchSize == 7)
        #expect(fetchRequest?.timeout == .seconds(13))
    }

    @Test("Runtime configuration update applies to subsequent sync")
    func runtimeConfigurationUpdateAppliesToSubsequentSync() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)

        let newTrack = Track(id: "NEW1", name: "New Song", artist: "Artist", album: "Album")
        await bridge.setLibrary(ids: ["NEW1"], tracks: ["NEW1": newTrack])
        await store.setStored([])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate
        )
        await service.updateRuntimeConfiguration(LibrarySyncRuntimeConfiguration(
            idsBatchSize: 3,
            fullLibraryFetchTimeout: .seconds(17),
            idsBatchFetchTimeout: .seconds(19)
        ))

        _ = try await service.detectChanges()

        let fetchRequest = await bridge.lastFetchTracksRequest()
        #expect(await bridge.lastFetchAllTrackIDsTimeout() == .seconds(17))
        #expect(fetchRequest?.batchSize == 3)
        #expect(fetchRequest?.timeout == .seconds(19))
    }

    @Test("Detect removed tracks")
    func detectRemovedTracks() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)

        await bridge.setLibrary(ids: ["T1"], tracks: [
            "T1": Track(id: "T1", name: "Stays", artist: "A", album: "B"),
        ])
        await store.setStored([
            Track(id: "T1", name: "Stays", artist: "A", album: "B"),
            Track(id: "T2", name: "Removed", artist: "A", album: "B"),
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate
        )

        let result = try await service.detectChanges()
        #expect(result.newTracks.isEmpty)
        #expect(result.removedTrackIDs == ["T2"])
    }

    @Test("Detect modified tracks via lastModified change")
    func detectModifiedTracks() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)

        let oldDate = Date().addingTimeInterval(-3600)
        let newDate = Date()

        await bridge.setLibrary(ids: ["T1"], tracks: [
            "T1": Track(id: "T1", name: "Track", artist: "A", album: "B", lastModified: newDate),
        ])
        await store.setStored([
            Track(id: "T1", name: "Track", artist: "A", album: "B", lastModified: oldDate),
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate
        )

        let result = try await service.detectChanges(forceMetadataRefresh: true)
        #expect(result.modifiedTracks.count == 1)
        #expect(result.modifiedTracks.first?.id == "T1")
    }

    @Test("Detect modified tracks by fingerprint when lastModified is unchanged")
    func detectModifiedTracksWithSameLastModifiedAndMetadataChange() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let modifiedDate = Date()

        await bridge.setLibrary(ids: ["T1"], tracks: [
            "T1": Track(
                id: "T1",
                name: "Track",
                artist: "A",
                album: "B",
                lastModified: modifiedDate,
                releaseYear: 2001
            ),
        ])
        await store.setStored([
            Track(id: "T1", name: "Track", artist: "A", album: "B", lastModified: modifiedDate, releaseYear: 1998),
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate
        )

        let result = try await service.detectChanges(forceMetadataRefresh: true)
        #expect(result.modifiedTracks.count == 1)
        #expect(result.modifiedTracks.first?.id == "T1")
    }

    @Test("Auto-sync denied for non-Pro tier")
    func autoSyncDeniedForFreeTier() async {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate
        )

        await #expect(throws: LibrarySyncError.self) {
            try await service.startAutoSync(interval: .seconds(60))
        }
    }

    @Test("Auto-sync denied for weekPass tier")
    func autoSyncDeniedForWeekPass() async {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .weekPass)

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate
        )

        await #expect(throws: LibrarySyncError.self) {
            try await service.startAutoSync(interval: .seconds(60))
        }
    }

    @Test("No changes detected returns empty result")
    func noChanges() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)

        let track = Track(id: "T1", name: "Track", artist: "A", album: "B")
        await bridge.setLibrary(ids: ["T1"], tracks: ["T1": track])
        await store.setStored([track])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate
        )

        let result = try await service.detectChanges()
        #expect(!result.hasChanges)
    }

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

    @Test("Missing force scan timestamp triggers initial metadata refresh")
    func missingForceScanTimestampTriggersInitialMetadataRefresh() async throws {
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

        #expect(result.modifiedTracks.map(\.id) == ["T1"])
        #expect(await bridge.fetchTracksRequestCount() == 1)
        #expect(metadata?.lastForceScanDate == now)
    }

    @Test("Synchronize now applies new modified and removed tracks to store")
    func synchronizeNowAppliesDetectedChanges() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let modifiedDate = Date()

        let newTrack = Track(id: "NEW", name: "New Song", artist: "Artist", album: "Album")
        let modifiedTrack = Track(
            id: "MOD",
            name: "Updated Song",
            artist: "Artist",
            album: "Album",
            lastModified: modifiedDate,
            releaseYear: 2024
        )

        await bridge.setLibrary(ids: ["NEW", "MOD"], tracks: [
            "NEW": newTrack,
            "MOD": modifiedTrack,
        ])
        await store.setStored([
            Track(id: "MOD", name: "Old Song", artist: "Artist", album: "Album", lastModified: modifiedDate),
            Track(id: "REMOVED", name: "Removed Song", artist: "Artist", album: "Album"),
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate
        )

        let result = try await service.synchronizeNow(forceMetadataRefresh: true)
        let storedTracks = await store.storedTracks

        #expect(result.newTracks.map(\.id) == ["NEW"])
        #expect(result.modifiedTracks.map(\.id) == ["MOD"])
        #expect(result.removedTrackIDs == ["REMOVED"])
        #expect(storedTracks.map(\.id).sorted() == ["MOD", "NEW"])
        #expect(storedTracks.first { $0.id == "MOD" }?.name == "Updated Song")
    }

    @Test("Synchronize now invalidates cache for modified identities and removed tracks")
    func synchronizeNowInvalidatesCacheForModifiedIdentitiesAndRemovedTracks() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let cache = MockCacheService()
        let snapshotService = SyncMockLibrarySnapshotService()

        let oldModified = Track(id: "MOD", name: "Song", artist: "Old Artist", album: "Old Album")
        let newModified = Track(id: "MOD", name: "Song", artist: "New Artist", album: "New Album")
        let removed = Track(id: "REMOVED", name: "Removed", artist: "Gone Artist", album: "Gone Album")
        await bridge.setLibrary(ids: ["MOD"], tracks: ["MOD": newModified])
        await store.setStored([oldModified, removed])
        await seedSyncCaches(cache, artist: "Old Artist", album: "Old Album")
        await seedSyncCaches(cache, artist: "New Artist", album: "New Album")
        await seedSyncCaches(cache, artist: "Gone Artist", album: "Gone Album")

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            cache: cache,
            librarySnapshotService: snapshotService
        )

        _ = try await service.synchronizeNow(forceMetadataRefresh: true)

        await expectSyncCachesInvalidated(cache, artist: "Old Artist", album: "Old Album")
        await expectSyncCachesInvalidated(cache, artist: "New Artist", album: "New Album")
        await expectSyncCachesInvalidated(cache, artist: "Gone Artist", album: "Gone Album")
        let wasCleared = await snapshotService.wasCleared()
        #expect(wasCleared)
    }
}

// MARK: - Mock Helpers

extension SyncMockScriptClient {
    func setLibrary(ids: [String], tracks: [String: Track]) {
        libraryTrackIDs = ids
        tracksByID = tracks
    }
}

extension SyncMockTrackStore {
    func setStored(_ tracks: [Track]) {
        storedTracks = tracks
    }
}

actor SyncMockLibrarySnapshotService: LibrarySnapshotService {
    var isEnabled = true
    var isDeltaEnabled = true
    private var didClearSnapshot = false
    private var metadata: LibraryCacheMetadata?

    func loadSnapshot() async throws -> [Track]? {
        nil
    }
    func saveSnapshot(_: [Track]) async throws -> String {
        "snapshot"
    }
    func clearSnapshot() async {
        didClearSnapshot = true
    }
    func isSnapshotValid() async -> Bool {
        true
    }
    func getSnapshotMetadata() async -> LibraryCacheMetadata? {
        metadata
    }
    func updateSnapshotMetadata(_ metadata: LibraryCacheMetadata) async throws {
        self.metadata = metadata
    }
    func loadDelta() async -> LibraryDeltaCache? {
        nil
    }
    func saveDelta(_: LibraryDeltaCache) async throws {}
    func getLibraryModificationDate() async throws -> Date {
        .distantPast
    }

    func wasCleared() -> Bool {
        didClearSnapshot
    }

    func setMetadata(_ metadata: LibraryCacheMetadata) {
        self.metadata = metadata
    }
}

func seedSyncCaches(_ cache: MockCacheService, artist: String, album: String) async {
    await cache.storeAlbumYear(artist: artist, album: album, year: 1970, confidence: 85)
    await cache.setCachedAPIResult(CachedAPIResult(
        artist: artist,
        album: album,
        year: 1970,
        source: "musicbrainz",
        timestamp: Date(),
        ttl: nil
    ))
}

func expectSyncCachesInvalidated(_ cache: MockCacheService, artist: String, album: String) async {
    let albumYear = await cache.getAlbumYear(artist: artist, album: album)
    let apiResult = await cache.getCachedAPIResult(
        artist: artist,
        album: album,
        source: "musicbrainz"
    )
    #expect(albumYear == nil)
    #expect(apiResult == nil)
}

// MARK: - SyncResult Tests

@Suite("SyncResult — hasChanges computed property")
struct SyncResultTests {
    @Test("hasChanges is false for empty result")
    func emptyResult() {
        let result = SyncResult()
        #expect(result.hasChanges == false)
    }

    @Test("hasChanges is true when newTracks is non-empty")
    func hasNewTracks() {
        let track = Track(id: "1", name: "Song", artist: "A", album: "B")
        let result = SyncResult(newTracks: [track])
        #expect(result.hasChanges == true)
    }

    @Test("hasChanges is true when removedTrackIDs is non-empty")
    func hasRemovedTracks() {
        let result = SyncResult(removedTrackIDs: ["1"])
        #expect(result.hasChanges == true)
    }

    @Test("hasChanges is true when modifiedTracks is non-empty")
    func hasModifiedTracks() {
        let track = Track(id: "1", name: "Song", artist: "A", album: "B")
        let result = SyncResult(modifiedTracks: [track])
        #expect(result.hasChanges == true)
    }
}

// MARK: - LibrarySyncError Tests

@Suite("LibrarySyncError — error descriptions")
struct LibrarySyncErrorTests {
    @Test("featureNotAvailable includes feature and tier info")
    func featureNotAvailable() {
        let error = LibrarySyncError.featureNotAvailable(
            feature: .autoSync,
            currentTier: .free
        )
        let description = error.errorDescription ?? ""
        #expect(description.contains("autoSync"))
        #expect(description.contains("free"))
    }

    @Test("syncAlreadyRunning has a description")
    func syncAlreadyRunning() {
        let error = LibrarySyncError.syncAlreadyRunning
        #expect(error.errorDescription?.isEmpty == false)
    }
}
