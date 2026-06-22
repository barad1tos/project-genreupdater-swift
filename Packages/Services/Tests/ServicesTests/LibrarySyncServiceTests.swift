import Foundation
import Testing
@testable import Core
@testable import Services

// MARK: - Configurable Mock Script Client

actor SyncMockScriptClient: AppleScriptClient {
    var libraryTrackIDs: [String] = []
    var tracksByID: [String: Track] = [:]
    private var fetchAllTrackIDsError: AppleScriptBridgeError?
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
        if let fetchAllTrackIDsError {
            throw fetchAllTrackIDsError
        }
        return libraryTrackIDs
    }

    func updateTrackProperty(
        trackID _: String,
        property _: String,
        value _: String
    ) async throws -> AppleScriptWriteResult {
        try Task.checkCancellation()
        return .changed
    }

    func batchUpdateTracks(_: [(trackID: String, property: String, value: String)]) async throws {
        try Task.checkCancellation()
    }

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

    @Test("Track ID fetch failure does not apply removals")
    func trackIDFetchFailureDoesNotApplyRemovals() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        await bridge.setFetchAllTrackIDsError(.executionFailed(
            scriptName: "fetch_track_ids",
            detail: "ERROR:Music failed"
        ))
        await store.setStored([
            Track(id: "T1", name: "Stored", artist: "A", album: "B"),
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate
        )

        await #expect(throws: AppleScriptBridgeError.self) {
            _ = try await service.synchronizeNow()
        }
        #expect(try await store.trackCount() == 1)
    }

    @Test("Ignore timestamp-only metadata churn during force scan")
    func ignoreTimestampOnlyMetadataChurnDuringForceScan() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)

        let oldDate = Date().addingTimeInterval(-3600)
        let newDate = Date()

        await bridge.setLibrary(ids: ["T1"], tracks: [
            "T1": Track(
                id: "T1",
                name: "Track",
                artist: "A",
                album: "B",
                genre: "Rock",
                year: 2001,
                dateAdded: newDate,
                lastModified: newDate,
                trackStatus: "matched"
            ),
        ])
        await store.setStored([
            Track(
                id: "T1",
                name: "Track",
                artist: "A",
                album: "B",
                genre: "Rock",
                year: 2001,
                dateAdded: oldDate,
                lastModified: oldDate,
                trackStatus: "matched"
            ),
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate
        )

        let result = try await service.detectChanges(forceMetadataRefresh: true)
        #expect(result.modifiedTracks.isEmpty)
    }

    @Test("Persisted release metadata does not repeat force-scan deltas")
    func persistedReleaseMetadataDoesNotRepeatForceScanDeltas() async throws {
        let bridge = SyncMockScriptClient()
        let store = try SwiftDataTrackStore.createInMemory()
        let gate = await FeatureGate(fixedTier: .free)
        let track = Track(
            id: "T1",
            name: "Track",
            artist: "A",
            album: "B",
            genre: "Rock",
            year: 2001,
            trackStatus: "matched",
            releaseYear: 2001
        )

        await bridge.setLibrary(ids: ["T1"], tracks: ["T1": track])
        try await store.saveTracks([track])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate
        )

        let result = try await service.detectChanges(forceMetadataRefresh: true)
        #expect(result.modifiedTracks.isEmpty)
    }

    @Test("Detect modified tracks by processing metadata even when lastModified is older")
    func detectModifiedTracksByProcessingMetadataWhenLastModifiedIsOlder() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let storedDate = Date()
        let currentDate = storedDate.addingTimeInterval(-3600)

        await bridge.setLibrary(ids: ["T1"], tracks: [
            "T1": Track(
                id: "T1",
                name: "Track",
                artist: "A",
                album: "B",
                genre: "Stoner Rock",
                year: 2001,
                lastModified: currentDate,
                trackStatus: "matched"
            ),
        ])
        await store.setStored([
            Track(
                id: "T1",
                name: "Track",
                artist: "A",
                album: "B",
                genre: "Rock",
                year: 1999,
                lastModified: storedDate,
                trackStatus: "uploaded"
            ),
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

    @Test("Synchronize now resolves prerelease pending after subscription transition")
    func synchronizeNowResolvesPrereleasePendingAfterSubscriptionTransition() async throws {
        let fixture = await makePrereleaseFixture(currentStatus: .subscription)

        let result = try await fixture.service.synchronizeNow(forceMetadataRefresh: true)
        let storedTracks = await fixture.store.storedTracks
        let removedAlbums = await fixture.pendingVerification.removedAlbums
        let removedAlbum = try #require(removedAlbums.first)
        let modifiedTrackIDs: [String] = result.modifiedTracks.map(\.id)

        #expect(modifiedTrackIDs == ["PRE"])
        #expect(storedTracks.first { $0.id == "PRE" }?.trackStatus == TrackKind.subscription.rawValue)
        #expect(removedAlbums.count == 1)
        #expect(removedAlbum.artist == "SubRosa")
        #expect(removedAlbum.album == "Future Album")
    }

    @Test("Synchronize now keeps prerelease pending after unavailable transition")
    func synchronizeNowKeepsPrereleasePendingAfterUnavailableTransition() async throws {
        let fixture = await makePrereleaseFixture(currentStatus: .noLongerAvailable)

        let result = try await fixture.service.synchronizeNow(forceMetadataRefresh: true)
        let storedTracks = await fixture.store.storedTracks
        let removedAlbums = await fixture.pendingVerification.removedAlbums
        let modifiedTrackIDs: [String] = result.modifiedTracks.map(\.id)

        #expect(modifiedTrackIDs == ["PRE"])
        #expect(storedTracks.first { $0.id == "PRE" }?.trackStatus == TrackKind.noLongerAvailable.rawValue)
        #expect(removedAlbums.isEmpty)
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

    private func makePrereleaseFixture(
        currentStatus: TrackKind
    ) async -> (
        store: SyncMockTrackStore,
        pendingVerification: PendingVerificationProbe,
        service: LibrarySyncService
    ) {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let pendingVerification = PendingVerificationProbe(entry: nil, isVerificationNeeded: false)
        let modifiedDate = Date()
        let storedTrack = Track(
            id: "PRE",
            name: "Future Song",
            artist: "SubRosa",
            album: "Future Album",
            lastModified: modifiedDate,
            trackStatus: TrackKind.prerelease.rawValue
        )
        let currentTrack = Track(
            id: "PRE",
            name: "Future Song",
            artist: "SubRosa",
            album: "Future Album",
            lastModified: modifiedDate,
            trackStatus: currentStatus.rawValue
        )
        await bridge.setLibrary(ids: ["PRE"], tracks: ["PRE": currentTrack])
        await store.setStored([storedTrack])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            pendingVerificationService: pendingVerification
        )
        return (store, pendingVerification, service)
    }
}

// MARK: - Mock Helpers

extension SyncMockScriptClient {
    func setLibrary(ids: [String], tracks: [String: Track]) {
        libraryTrackIDs = ids
        tracksByID = tracks
    }

    func setFetchAllTrackIDsError(_ error: AppleScriptBridgeError) {
        fetchAllTrackIDsError = error
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
    func saveDelta(_: LibraryDeltaCache) async throws {
        // Tests using this mock do not assert delta persistence.
    }
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

final class SyncDateProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func now() -> Date {
        lock.withLock {
            date
        }
    }

    func set(_ date: Date) {
        lock.withLock {
            self.date = date
        }
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
