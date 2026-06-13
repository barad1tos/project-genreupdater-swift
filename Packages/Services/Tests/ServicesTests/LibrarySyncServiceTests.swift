import Foundation
import Testing
@testable import Core
@testable import Services

// MARK: - Configurable Mock Script Client

actor SyncMockScriptClient: AppleScriptClient {
    var libraryTrackIDs: [String] = []
    var tracksByID: [String: Track] = [:]
    private var fetchTracksRequests: [(batchSize: Int, timeout: Duration?)] = []
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
        fetchTracksRequests.append((batchSize: batchSize, timeout: timeout))
        return trackIDs.compactMap { tracksByID[$0] }
    }

    func fetchAllTrackIDs(timeout: Duration?) async throws -> [String] {
        fetchAllTrackIDsTimeouts.append(timeout)
        return libraryTrackIDs
    }

    func updateTrackProperty(trackID: String, property: String, value: String) async throws {}

    func lastFetchTracksRequest() -> (batchSize: Int, timeout: Duration?)? {
        fetchTracksRequests.last
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
        storedTracks = tracks
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

        let result = try await service.detectChanges()
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
            Track(
                id: "T1",
                name: "Track",
                artist: "A",
                album: "B",
                lastModified: modifiedDate,
                releaseYear: 1998
            ),
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate
        )

        let result = try await service.detectChanges()
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

// MARK: - Auto-Sync Lifecycle Tests

@Suite("LibrarySyncService — auto-sync start/stop lifecycle")
struct LibrarySyncAutoSyncTests {
    @Test("Start and stop auto-sync without crash")
    @MainActor
    func startAndStop() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = FeatureGate(fixedTier: .pro)

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate
        )

        try await service.startAutoSync(interval: .seconds(300))
        let running = await service.isAutoSyncRunning
        #expect(running == true)

        await service.stopAutoSync()
        let stopped = await service.isAutoSyncRunning
        #expect(stopped == false)
    }

    @Test("Double start throws syncAlreadyRunning")
    @MainActor
    func doubleStartThrows() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = FeatureGate(fixedTier: .pro)

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate
        )

        try await service.startAutoSync(interval: .seconds(300))
        await #expect(throws: LibrarySyncError.self) {
            try await service.startAutoSync(interval: .seconds(300))
        }
        await service.stopAutoSync()
    }

    @Test("isAutoSyncRunning is false initially")
    @MainActor
    func notRunningInitially() async {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = FeatureGate(fixedTier: .pro)

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate
        )

        let running = await service.isAutoSyncRunning
        #expect(running == false)
    }

    @Test("Detect modified tracks by field change (no lastModified)")
    func detectModifiedByFieldChange() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)

        // Same track but with changed genre
        await bridge.setLibrary(ids: ["T1"], tracks: [
            "T1": Track(id: "T1", name: "Song", artist: "A", album: "B", genre: "Metal"),
        ])
        await store.setStored([
            Track(id: "T1", name: "Song", artist: "A", album: "B", genre: "Rock"),
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate
        )

        let result = try await service.detectChanges()
        #expect(result.modifiedTracks.count == 1)
    }

    @Test("Detect modified tracks by name change")
    func detectModifiedByNameChange() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)

        await bridge.setLibrary(ids: ["T1"], tracks: [
            "T1": Track(id: "T1", name: "New Name", artist: "A", album: "B"),
        ])
        await store.setStored([
            Track(id: "T1", name: "Old Name", artist: "A", album: "B"),
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate
        )

        let result = try await service.detectChanges()
        #expect(result.modifiedTracks.count == 1)
    }
}
