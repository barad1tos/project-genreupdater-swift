import Testing
@testable import Core
@testable import Services

@Suite("Library sync album identity")
struct LibrarySyncIdentityTests {
    @Test("Resolves prerelease pending with album identity aliases")
    func resolvesPrereleasePendingWithAlbumIdentityAliases() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let pendingVerification = PendingVerificationProbe(entry: nil, isVerificationNeeded: false)
        let storedTrack = Track(
            id: "PRE",
            name: "Future Song",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            trackStatus: TrackKind.prerelease.rawValue
        )
        let currentTrack = Track(
            id: "PRE",
            name: "Future Song",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            trackStatus: TrackKind.subscription.rawValue
        )
        await bridge.setLibrary(ids: ["PRE"], tracks: ["PRE": currentTrack])
        await store.setStored([storedTrack])
        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            pendingVerificationService: pendingVerification
        )

        _ = try await service.synchronizeNow(forceMetadataRefresh: true)

        let removedAlbums = await pendingVerification.removedAlbums
        #expect(removedAlbums.contains { removal in
            removal.artist == "Daft Punk" && removal.album == "Random Access Memories"
        })
        #expect(removedAlbums.contains { removal in
            removal.artist == "Daft Punk feat. Pharrell Williams" && removal.album == "Random Access Memories"
        })
    }
}
