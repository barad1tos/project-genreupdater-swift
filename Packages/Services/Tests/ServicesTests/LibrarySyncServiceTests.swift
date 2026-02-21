import Foundation
import Testing
@testable import Core
@testable import Services

// MARK: - Configurable Mock Script Client

actor SyncMockScriptClient: AppleScriptClient {
    var libraryTrackIDs: [String] = []
    var tracksByID: [String: Track] = [:]

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
        trackIDs.compactMap { tracksByID[$0] }
    }

    func fetchAllTrackIDs(timeout: Duration?) async throws -> [String] {
        libraryTrackIDs
    }

    func updateTrackProperty(trackID: String, property: String, value: String) async throws {}
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
