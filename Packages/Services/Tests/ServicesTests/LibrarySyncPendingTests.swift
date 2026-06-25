import Testing
@testable import Core
@testable import Services

@Suite("LibrarySyncService — pending verification cleanup")
struct LibrarySyncPendingTests {
    @Test("Sync removes pending prerelease row when the album disappears")
    func syncRemovesPendingPrereleaseRowWhenAlbumDisappears() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let pending = PendingVerificationProbe(
            entry: PendingAlbumEntry(
                id: "pending-prerelease",
                artist: "Gone Artist",
                album: "Future Album",
                reason: "prerelease"
            ),
            isVerificationNeeded: true
        )

        await bridge.setLibrary(ids: ["T1"], tracks: [
            "T1": Track(id: "T1", name: "Stays", artist: "Artist", album: "Album"),
        ])
        await store.setStored([
            Track(id: "T1", name: "Stays", artist: "Artist", album: "Album"),
            Track(
                id: "T2",
                name: "Future Track",
                artist: "Gone Artist",
                album: "Future Album",
                trackStatus: TrackKind.prerelease.rawValue
            ),
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            pendingVerificationService: pending
        )

        _ = try await service.synchronizeNow()

        let removedAlbums = await pending.removedAlbums
        #expect(removedAlbums.map(\.album) == ["Future Album"])
    }
}
