import Core
import Testing
@testable import Services

@Suite("LibrarySyncService — read provider mutation metadata")
struct ReadProviderMetadataTests {
    @Test("Read provider mutation metadata fetches only candidate artists")
    func readProviderMutationMetadataFetchesOnlyCandidateArtists() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let readProvider = SyncMockReadProvider()

        await configureFixture(bridge: bridge, store: store, readProvider: readProvider)

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            readProvider: readProvider
        )

        let result = try await service.detectChanges()

        #expect(result.newTracks.map(\.id) == ["MK-2"])
        #expect(result.newTracks.first?.appleScriptID == "AS-2")
        #expect(result.newTracks.first?.genre == "Metal")
        #expect(await bridge.fetchAllTrackIDsCallCount() == 0)
        #expect(await bridge.fetchTracksRequestCount() == 0)
        #expect(await bridge.fetchedArtists().compactMap(\.self) == ["Candidate Artist"])
    }

    private func configureFixture(
        bridge: SyncMockScriptClient,
        store: SyncMockTrackStore,
        readProvider: SyncMockReadProvider
    ) async {
        await readProvider.setTracks([
            Track(
                id: "MK-1",
                name: "Existing",
                artist: "Stored Artist",
                album: "B",
                appleScriptID: "AS-1"
            ),
            Track(id: "MK-2", name: "New", artist: "Candidate Artist", album: "B", appleScriptID: nil),
        ])
        await bridge.setLibrary(ids: ["AS-1", "AS-2", "AS-UNRELATED"], tracks: [
            "AS-1": Track(
                id: "AS-1",
                name: "Existing",
                artist: "Stored Artist",
                album: "B",
                appleScriptID: "AS-1"
            ),
            "AS-2": Track(
                id: "AS-2",
                name: "New",
                artist: "Candidate Artist",
                album: "B",
                genre: "Metal",
                appleScriptID: "AS-2"
            ),
            "AS-UNRELATED": Track(id: "AS-UNRELATED", name: "Other", artist: "Other Artist", album: "B"),
        ])
        await bridge.setArtistTracks([
            Track(
                id: "AS-2",
                name: "New",
                artist: "Candidate Artist",
                album: "B",
                genre: "Metal",
                appleScriptID: "AS-2"
            ),
        ], for: "Candidate Artist")
        await store.setStored([
            Track(
                id: "MK-1",
                name: "Existing",
                artist: "Stored Artist",
                album: "B",
                appleScriptID: "AS-1"
            ),
        ])
    }
}
