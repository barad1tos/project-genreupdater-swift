import Testing
@testable import Core
@testable import Services

@Suite("LibrarySyncService - read-provider identity mapping")
struct LibrarySyncMappingTests {
    @Test("Read provider sync enriches new MusicKit rows with AppleScript metadata")
    func readProviderSyncEnrichesNewMusicKitRowsWithAppleScriptMetadata() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let readProvider = SyncMockReadProvider()

        await readProvider.setTracks([
            Track(id: "MK-1", name: "Existing", artist: "A", album: "B", appleScriptID: "AS-1"),
            Track(id: "MK-2", name: "New", artist: "A", album: "B", appleScriptID: nil)
        ])
        await bridge.setLibrary(ids: ["AS-1", "AS-2"], tracks: [
            "AS-1": Track(id: "AS-1", name: "Existing", artist: "A", album: "B"),
            "AS-2": Track(id: "AS-2", name: "New", artist: "A", album: "B", genre: "Metal")
        ])
        await store.setStored([
            Track(id: "MK-1", name: "Existing", artist: "A", album: "B", appleScriptID: "AS-1")
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            readProvider: readProvider
        )

        let result = try await service.detectChanges()

        #expect(result.newTracks.map(\.id) == ["MK-2"])
        #expect(result.newTracks.first?.appleScriptID == "AS-2")
        #expect(result.newTracks.first?.genre == "Metal")
        #expect(result.removedTrackIDs.isEmpty)
        #expect(await bridge.fetchAllTrackIDsCallCount() == 0)
        #expect(await bridge.fetchTracksRequestCount() == 0)
        #expect(await bridge.fetchedArtists().compactMap(\.self) == ["A"])
        #expect(await readProvider.requestCount() == 1)
    }

    @Test("Read provider sync tolerates duplicate MusicKit IDs")
    func readProviderSyncToleratesDuplicateMusicKitIDs() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let readProvider = SyncMockReadProvider()

        await readProvider.setTracks([
            Track(id: "MK-1", name: "First", artist: "", album: "B"),
            Track(id: "MK-1", name: "Latest", artist: "", album: "B")
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            readProvider: readProvider
        )

        let result = try await service.detectChanges()

        #expect(result.newTracks.map(\.name) == ["Latest"])
        #expect(result.removedTrackIDs.isEmpty)
        #expect(await bridge.fetchAllTrackIDsCallCount() == 0)
        #expect(await bridge.fetchTracksRequestCount() == 0)
        #expect(await bridge.fetchedArtists().isEmpty)
    }

    @Test("Read provider sync confirms removals through AppleScript IDs")
    func readProviderSyncConfirmsRemovalsThroughAppleScriptIDs() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let readProvider = SyncMockReadProvider()

        await readProvider.setTracks([
            Track(id: "MK-1", name: "Existing", artist: "A", album: "B", appleScriptID: "AS-1")
        ])
        await bridge.setLibrary(ids: ["AS-1"], tracks: [
            "AS-1": Track(id: "AS-1", name: "Existing", artist: "A", album: "B", appleScriptID: "AS-1")
        ])
        await store.setStored([
            Track(id: "MK-1", name: "Existing", artist: "A", album: "B", appleScriptID: "AS-1"),
            Track(id: "MK-2", name: "Removed", artist: "A", album: "B", appleScriptID: "AS-2")
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            readProvider: readProvider
        )

        let result = try await service.synchronizeNow()
        let remainingIDs = try await store.loadAllTracks().map(\.id).sorted()

        #expect(result.removedTrackIDs == ["MK-2"])
        #expect(remainingIDs == ["MK-1"])
        #expect(await bridge.fetchTracksRequestCount() == 1)
        #expect(await bridge.fetchAllTrackIDsCallCount() == 1)
    }

    @Test("Read provider sync preserves rows without AppleScript IDs when candidate has no artist scope")
    func readProviderSyncPreservesRowsWithoutAppleScriptIDsWhenCandidateHasNoArtistScope() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let readProvider = SyncMockReadProvider()

        await readProvider.setTracks([
            Track(id: "MK-1", name: "Existing", artist: "A", album: "B")
        ])
        await store.setStored([
            Track(id: "MK-1", name: "Existing", artist: "A", album: "B"),
            Track(id: "MK-2", name: "Removed", artist: "", album: "B")
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            readProvider: readProvider
        )

        let result = try await service.synchronizeNow()
        let remainingIDs = try await store.loadAllTracks().map(\.id).sorted()

        #expect(result.removedTrackIDs.isEmpty)
        #expect(remainingIDs == ["MK-1", "MK-2"])
        #expect(await bridge.fetchTracksRequestCount() == 0)
        #expect(await bridge.fetchAllTrackIDsCallCount() == 0)
        #expect(await bridge.fetchedArtists().isEmpty)
    }

    @Test("Read provider sync removes unmapped MusicKit rows after AppleScript metadata check")
    func readProviderSyncRemovesUnmappedMusicKitRowsAfterAppleScriptMetadataCheck() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let readProvider = SyncMockReadProvider()

        await readProvider.setTracks([
            Track(id: "MK-1", name: "New", artist: "A", album: "B")
        ])
        await bridge.setLibrary(ids: ["AS-1"], tracks: [
            "AS-1": Track(id: "AS-1", name: "Existing", artist: "A", album: "B", appleScriptID: "AS-1")
        ])
        await store.setStored([
            Track(id: "MK-2", name: "Removed", artist: "A", album: "B"),
            Track(id: "MK-AS", name: "Existing", artist: "A", album: "B", appleScriptID: "AS-1")
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            readProvider: readProvider
        )

        let result = try await service.synchronizeNow()
        let remainingIDs = try await store.loadAllTracks().map(\.id).sorted()

        #expect(result.removedTrackIDs == ["MK-2"])
        #expect(remainingIDs == ["MK-1", "MK-AS"])
        #expect(await bridge.fetchTracksRequestCount() == 1)
        #expect(await bridge.fetchAllTrackIDsCallCount() == 1)
        #expect(await bridge.fetchedArtists().compactMap(\.self) == ["A"])
    }
}

@Suite("LibrarySyncService - read-provider fallback")
struct LibrarySyncFallbackTests {
    @Test("Read provider sync preserves unmapped rows when AppleScript has a possible identity match")
    func readProviderSyncPreservesUnmappedRowsWithPossibleAppleScriptIdentityMatch() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let readProvider = SyncMockReadProvider()

        await readProvider.setTracks([
            Track(id: "MK-1", name: "Existing", artist: "A", album: "B", appleScriptID: "AS-1")
        ])
        await bridge.setLibrary(ids: ["AS-1", "AS-2", "AS-3"], tracks: [
            "AS-1": Track(id: "AS-1", name: "Existing", artist: "A", album: "B", appleScriptID: "AS-1"),
            "AS-2": Track(id: "AS-2", name: "Ambiguous", artist: "A", album: "B", appleScriptID: "AS-2"),
            "AS-3": Track(id: "AS-3", name: "Ambiguous", artist: "A", album: "B", appleScriptID: "AS-3")
        ])
        await store.setStored([
            Track(id: "MK-1", name: "Existing", artist: "A", album: "B", appleScriptID: "AS-1"),
            Track(id: "MK-2", name: "Ambiguous", artist: "A", album: "B")
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            readProvider: readProvider
        )

        let result = try await service.synchronizeNow()
        let remainingIDs = try await store.loadAllTracks().map(\.id).sorted()

        #expect(result.removedTrackIDs.isEmpty)
        #expect(remainingIDs == ["MK-1", "MK-2"])
        #expect(await bridge.fetchTracksRequestCount() == 0)
        #expect(await bridge.fetchAllTrackIDsCallCount() == 0)
        #expect(await bridge.fetchedArtists().compactMap(\.self) == ["A"])
    }

    @Test("Read provider sync keeps MusicKit-only rows when MusicKit snapshot is empty")
    func readProviderSyncKeepsMusicKitOnlyRowsWhenMusicKitSnapshotIsEmpty() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let readProvider = SyncMockReadProvider()

        await readProvider.setTracks([])
        await store.setStored([
            Track(id: "MK-1", name: "Existing", artist: "A", album: "B")
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            readProvider: readProvider
        )

        let result = try await service.synchronizeNow()
        let remainingIDs = try await store.loadAllTracks().map(\.id)

        #expect(result.removedTrackIDs.isEmpty)
        #expect(remainingIDs == ["MK-1"])
        #expect(await bridge.fetchTracksRequestCount() == 0)
        #expect(await bridge.fetchAllTrackIDsCallCount() == 0)
    }

    @Test("Read provider sync keeps stored tracks when MusicKit snapshot is empty")
    func readProviderSyncKeepsStoredTracksWhenMusicKitSnapshotIsEmpty() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let readProvider = SyncMockReadProvider()

        await readProvider.setTracks([])
        await bridge.setLibrary(ids: ["AS-1"], tracks: [
            "AS-1": Track(id: "AS-1", name: "Existing", artist: "A", album: "B", appleScriptID: "AS-1")
        ])
        await store.setStored([
            Track(id: "MK-1", name: "Existing", artist: "A", album: "B", appleScriptID: "AS-1")
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            readProvider: readProvider
        )

        let result = try await service.synchronizeNow()
        let remainingIDs = try await store.loadAllTracks().map(\.id)

        #expect(result.removedTrackIDs.isEmpty)
        #expect(remainingIDs == ["MK-1"])
        #expect(await bridge.fetchTracksRequestCount() == 1)
        #expect(await bridge.fetchAllTrackIDsCallCount() == 0)
    }

    @Test("Read provider sync falls back when stored tracks are AppleScript keyed")
    func readProviderSyncFallsBackWhenStoredTracksAreAppleScriptKeyed() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let readProvider = SyncMockReadProvider()

        await readProvider.setTracks([
            Track(id: "MK-1", name: "Existing", artist: "A", album: "B")
        ])
        await bridge.setLibrary(ids: ["AS-1"], tracks: [
            "AS-1": Track(id: "AS-1", name: "Existing", artist: "A", album: "B", appleScriptID: "AS-1")
        ])
        await store.setStored([
            Track(id: "AS-1", name: "Existing", artist: "A", album: "B", appleScriptID: "AS-1")
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            readProvider: readProvider
        )

        let result = try await service.detectChanges()

        #expect(!result.hasChanges)
        #expect(await bridge.fetchAllTrackIDsCallCount() == 1)
        #expect(await bridge.fetchTracksRequestCount() == 0)
        #expect(await readProvider.requestCount() == 1)
    }

    @Test("Read provider sync falls back when legacy rows lack AppleScript IDs")
    func readProviderSyncFallsBackWhenLegacyRowsLackAppleScriptIDs() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let readProvider = SyncMockReadProvider()

        await readProvider.setTracks([
            Track(id: "MK-1", name: "Existing", artist: "A", album: "B")
        ])
        await bridge.setLibrary(ids: ["AS-LEGACY"], tracks: [
            "AS-LEGACY": Track(id: "AS-LEGACY", name: "Existing", artist: "A", album: "B")
        ])
        await store.setStored([
            Track(id: "AS-LEGACY", name: "Existing", artist: "A", album: "B")
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            readProvider: readProvider
        )

        let result = try await service.detectChanges()

        #expect(!result.hasChanges)
        #expect(await bridge.fetchAllTrackIDsCallCount() >= 1)
        #expect(await bridge.fetchTracksRequestCount() == 0)
        #expect(await readProvider.requestCount() == 1)
    }
}
