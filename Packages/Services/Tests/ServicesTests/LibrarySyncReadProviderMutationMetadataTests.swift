import Core
import Testing
@testable import Services

@Suite("LibrarySyncService — read provider mutation metadata")
struct ReadProviderMetadataTests {
    @Test("Read provider mutation metadata uses scoped artist fetch when candidates share one artist")
    func readProviderMutationMetadataUsesScopedArtistFetch() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let readProvider = SyncMockReadProvider()

        await readProvider.setTracks([
            Track(id: "MK-new", name: "New", artist: "Scoped Artist", album: "B", appleScriptID: nil),
        ])
        await bridge.setLibrary(ids: ["AS-new", "AS-other"], tracks: [
            "AS-new": Track(id: "AS-new", name: "New", artist: "Scoped Artist", album: "B", appleScriptID: "AS-new"),
            "AS-other": Track(id: "AS-other", name: "Other", artist: "Other Artist", album: "B"),
        ])
        await bridge.setArtistTracks([
            Track(id: "AS-new", name: "New", artist: "Scoped Artist", album: "B", appleScriptID: "AS-new"),
        ], for: "Scoped Artist")

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            readProvider: readProvider
        )

        let result = try await service.detectChanges()

        #expect(result.newTracks.compactMap(\.appleScriptID) == ["AS-new"])
        #expect(await bridge.fetchAllTrackIDsCallCount() == 0)
        #expect(await bridge.fetchTracksRequestCount() == 0)
        #expect(await bridge.fetchedArtists().compactMap(\.self) == ["Scoped Artist"])
    }

    @Test("Read provider mutation metadata verifies empty scoped fetches before removal")
    func readProviderMutationMetadataVerifiesEmptyScopedFetchesBeforeRemoval() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let readProvider = SyncMockReadProvider()

        await readProvider.setTracks([
            Track(id: "MK-current", name: "Current", artist: "Stable Artist", album: "B"),
        ])
        await store.setStored([
            Track(id: "MK-current", name: "Current", artist: "Stable Artist", album: "B"),
            Track(id: "MK-removed", name: "Removed", artist: "Scoped Artist", album: "B", appleScriptID: nil),
        ])
        await bridge.setLibrary(ids: ["AS-other"], tracks: [
            "AS-other": Track(id: "AS-other", name: "Other", artist: "Other Artist", album: "B"),
        ])
        await bridge.setArtistTracks([], for: "Scoped Artist")

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            readProvider: readProvider
        )

        let result = try await service.detectChanges()

        #expect(result.removedTrackIDs == ["MK-removed"])
        #expect(await bridge.fetchAllTrackIDsCallCount() == 1)
        #expect(await bridge.fetchTracksRequestCount() == 1)
        #expect(await bridge.fetchedArtists().compactMap(\.self) == ["Scoped Artist"])
    }

    @Test("Read provider mutation metadata falls back for multiple artist scopes")
    func readProviderMutationMetadataFallsBackForMultipleArtistScopes() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let readProvider = SyncMockReadProvider()

        await readProvider.setTracks([
            Track(id: "MK-1", name: "First", artist: "First Artist", album: "B", appleScriptID: nil),
            Track(id: "MK-2", name: "Second", artist: "Second Artist", album: "B", appleScriptID: nil),
        ])
        await bridge.setLibrary(ids: ["AS-1", "AS-2"], tracks: [
            "AS-1": Track(id: "AS-1", name: "First", artist: "First Artist", album: "B", appleScriptID: "AS-1"),
            "AS-2": Track(id: "AS-2", name: "Second", artist: "Second Artist", album: "B", appleScriptID: "AS-2"),
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            readProvider: readProvider
        )

        let result = try await service.detectChanges()

        #expect(result.newTracks.compactMap(\.appleScriptID).sorted() == ["AS-1", "AS-2"])
        #expect(await bridge.fetchAllTrackIDsCallCount() == 1)
        #expect(await bridge.fetchTracksRequestCount() == 1)
        #expect(await bridge.fetchedArtists().isEmpty)
    }

    @Test("Read provider mutation metadata preserves artistless removals through full fallback")
    func readProviderMutationMetadataPreservesArtistlessRemovalsThroughFullFallback() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let readProvider = SyncMockReadProvider()

        await readProvider.setTracks([
            Track(id: "MK-current", name: "Current", artist: "Stable Artist", album: "B"),
            Track(id: "MK-new", name: "New", artist: "Scoped Artist", album: "B", appleScriptID: nil),
        ])
        await store.setStored([
            Track(id: "MK-current", name: "Current", artist: "Stable Artist", album: "B"),
            Track(id: "MK-artistless", name: "Blank Artist", artist: "", album: "B", appleScriptID: nil),
        ])
        await bridge.setLibrary(ids: ["AS-new", "AS-artistless"], tracks: [
            "AS-new": Track(id: "AS-new", name: "New", artist: "Scoped Artist", album: "B", appleScriptID: "AS-new"),
            "AS-artistless": Track(
                id: "AS-artistless",
                name: "Blank Artist",
                artist: "",
                album: "B",
                appleScriptID: "AS-artistless"
            ),
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            readProvider: readProvider
        )

        let result = try await service.detectChanges()

        #expect(result.removedTrackIDs.isEmpty)
        #expect(result.newTracks.compactMap(\.appleScriptID) == ["AS-new"])
        #expect(await bridge.fetchAllTrackIDsCallCount() == 1)
        #expect(await bridge.fetchTracksRequestCount() == 2)
        #expect(await bridge.fetchedArtists().isEmpty)
    }

    @Test("Read provider mutation metadata removes artistless removals when full fallback confirms absence")
    func readProviderMutationMetadataRemovesArtistlessRemovalsWhenFullFallbackConfirmsAbsence() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let readProvider = SyncMockReadProvider()

        await readProvider.setTracks([
            Track(id: "MK-current", name: "Current", artist: "Stable Artist", album: "B"),
            Track(id: "MK-new", name: "New", artist: "Scoped Artist", album: "B", appleScriptID: nil),
        ])
        await store.setStored([
            Track(id: "MK-current", name: "Current", artist: "Stable Artist", album: "B"),
            Track(id: "MK-artistless", name: "Blank Artist", artist: "", album: "B", appleScriptID: nil),
        ])
        await bridge.setLibrary(ids: ["AS-new"], tracks: [
            "AS-new": Track(id: "AS-new", name: "New", artist: "Scoped Artist", album: "B", appleScriptID: "AS-new"),
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            readProvider: readProvider
        )

        let result = try await service.detectChanges()

        #expect(result.removedTrackIDs == ["MK-artistless"])
        #expect(result.newTracks.compactMap(\.appleScriptID) == ["AS-new"])
        #expect(await bridge.fetchAllTrackIDsCallCount() == 1)
        #expect(await bridge.fetchTracksRequestCount() == 1)
        #expect(await bridge.fetchedArtists().isEmpty)
    }
}
