import Testing
@testable import Core
@testable import Services

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

        let result = try await service.detectChanges(forceMetadataRefresh: true)
        #expect(result.modifiedTracks.count == 1)
    }

    @Test("Detect modified tracks by year change")
    func detectModifiedByYearChange() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)

        await bridge.setLibrary(ids: ["T1"], tracks: [
            "T1": Track(id: "T1", name: "Song", artist: "A", album: "B", year: 2002),
        ])
        await store.setStored([
            Track(id: "T1", name: "Song", artist: "A", album: "B", year: 2001),
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate
        )

        let result = try await service.detectChanges(forceMetadataRefresh: true)
        #expect(result.modifiedTracks.count == 1)
    }
}
