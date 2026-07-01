import Core
import Testing
@testable import Services

@Suite("LibrarySyncService — read provider mutation metadata")
struct ReadProviderMetadataTests {
    @Test("Read provider mutation metadata uses scoped artist fetch when candidates share one artist")
    func readProviderMutationMetadataUsesScopedArtistFetch() async throws {
        let context = await makeSyncContext()

        await context.readProvider.setTracks([
            Track(id: "MK-new", name: "New", artist: "Scoped Artist", album: "B", appleScriptID: nil)
        ])
        await context.bridge.setLibrary(ids: ["AS-new", "AS-other"], tracks: [
            "AS-new": Track(id: "AS-new", name: "New", artist: "Scoped Artist", album: "B", appleScriptID: "AS-new"),
            "AS-other": Track(id: "AS-other", name: "Other", artist: "Other Artist", album: "B")
        ])
        await context.bridge.setArtistTracks([
            Track(id: "AS-new", name: "New", artist: "Scoped Artist", album: "B", appleScriptID: "AS-new")
        ], for: "Scoped Artist")

        let result = try await context.service.detectChanges()

        #expect(result.newTracks.compactMap(\.appleScriptID) == ["AS-new"])
        #expect(await context.bridge.fetchAllTrackIDsCallCount() == 0)
        #expect(await context.bridge.fetchTracksRequestCount() == 0)
        #expect(await context.bridge.fetchedArtists().compactMap(\.self) == ["Scoped Artist"])
    }

    @Test("Read provider mutation metadata verifies empty scoped fetches before removal")
    func readProviderMutationMetadataVerifiesEmptyScopedFetchesBeforeRemoval() async throws {
        let context = await makeSyncContext()

        await context.readProvider.setTracks([
            Track(id: "MK-current", name: "Current", artist: "Stable Artist", album: "B")
        ])
        await context.store.setStored([
            Track(id: "MK-current", name: "Current", artist: "Stable Artist", album: "B"),
            Track(id: "MK-removed", name: "Removed", artist: "Scoped Artist", album: "B", appleScriptID: nil)
        ])
        await context.bridge.setLibrary(ids: ["AS-other"], tracks: [
            "AS-other": Track(id: "AS-other", name: "Other", artist: "Other Artist", album: "B")
        ])
        await context.bridge.setArtistTracks([], for: "Scoped Artist")

        let result = try await context.service.detectChanges()

        #expect(result.removedTrackIDs == ["MK-removed"])
        #expect(await context.bridge.fetchAllTrackIDsCallCount() == 1)
        #expect(await context.bridge.fetchTracksRequestCount() == 1)
        #expect(await context.bridge.fetchedArtists().compactMap(\.self) == ["Scoped Artist"])
    }

    @Test("Read provider mutation metadata falls back for multiple artist scopes")
    func readProviderMutationMetadataFallsBackForMultipleArtistScopes() async throws {
        let context = await makeSyncContext()

        await context.readProvider.setTracks([
            Track(id: "MK-1", name: "First", artist: "First Artist", album: "B", appleScriptID: nil),
            Track(id: "MK-2", name: "Second", artist: "Second Artist", album: "B", appleScriptID: nil)
        ])
        await context.bridge.setLibrary(ids: ["AS-1", "AS-2"], tracks: [
            "AS-1": Track(id: "AS-1", name: "First", artist: "First Artist", album: "B", appleScriptID: "AS-1"),
            "AS-2": Track(id: "AS-2", name: "Second", artist: "Second Artist", album: "B", appleScriptID: "AS-2")
        ])

        let result = try await context.service.detectChanges()

        #expect(result.newTracks.compactMap(\.appleScriptID).sorted() == ["AS-1", "AS-2"])
        #expect(await context.bridge.fetchAllTrackIDsCallCount() == 1)
        #expect(await context.bridge.fetchTracksRequestCount() == 1)
        #expect(await context.bridge.fetchedArtists().isEmpty)
    }

    @Test("Read provider mutation metadata preserves artistless removals through full fallback")
    func readProviderMutationMetadataPreservesArtistlessRemovalsThroughFullFallback() async throws {
        let context = await makeSyncContext()

        await seedArtistlessFallback(
            context: context,
            includesAppleScriptArtistlessMatch: true
        )

        let result = try await context.service.detectChanges()

        #expect(result.removedTrackIDs.isEmpty)
        #expect(result.newTracks.compactMap(\.appleScriptID) == ["AS-new"])
        #expect(await context.bridge.fetchAllTrackIDsCallCount() == 1)
        #expect(await context.bridge.fetchTracksRequestCount() == 2)
        #expect(await context.bridge.fetchedArtists().isEmpty)
    }

    @Test("Read provider mutation metadata removes artistless removals when full fallback confirms absence")
    func readProviderMutationMetadataRemovesArtistlessRemovalsWhenFullFallbackConfirmsAbsence() async throws {
        let context = await makeSyncContext()

        await seedArtistlessFallback(
            context: context,
            includesAppleScriptArtistlessMatch: false
        )

        let result = try await context.service.detectChanges()

        #expect(result.removedTrackIDs == ["MK-artistless"])
        #expect(result.newTracks.compactMap(\.appleScriptID) == ["AS-new"])
        #expect(await context.bridge.fetchAllTrackIDsCallCount() == 1)
        #expect(await context.bridge.fetchTracksRequestCount() == 1)
        #expect(await context.bridge.fetchedArtists().isEmpty)
    }

    private func seedArtistlessFallback(
        context: SyncContext,
        includesAppleScriptArtistlessMatch: Bool
    ) async {
        await context.readProvider.setTracks([
            Track(id: "MK-current", name: "Current", artist: "Stable Artist", album: "B"),
            Track(id: "MK-new", name: "New", artist: "Scoped Artist", album: "B", appleScriptID: nil)
        ])
        await context.store.setStored([
            Track(id: "MK-current", name: "Current", artist: "Stable Artist", album: "B"),
            Track(id: "MK-artistless", name: "Blank Artist", artist: "", album: "B", appleScriptID: nil)
        ])

        var appleScriptTracks = [
            "AS-new": Track(id: "AS-new", name: "New", artist: "Scoped Artist", album: "B", appleScriptID: "AS-new")
        ]
        var appleScriptIDs = ["AS-new"]
        if includesAppleScriptArtistlessMatch {
            appleScriptTracks["AS-artistless"] = Track(
                id: "AS-artistless",
                name: "Blank Artist",
                artist: "",
                album: "B",
                appleScriptID: "AS-artistless"
            )
            appleScriptIDs.append("AS-artistless")
        }
        await context.bridge.setLibrary(ids: appleScriptIDs, tracks: appleScriptTracks)
    }

    private func makeSyncContext() async -> SyncContext {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let readProvider = SyncMockReadProvider()
        let featureGate = await FeatureGate(fixedTier: .free)
        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: featureGate,
            readProvider: readProvider
        )
        return SyncContext(
            bridge: bridge,
            store: store,
            readProvider: readProvider,
            service: service
        )
    }

    private struct SyncContext {
        let bridge: SyncMockScriptClient
        let store: SyncMockTrackStore
        let readProvider: SyncMockReadProvider
        let service: LibrarySyncService
    }
}
