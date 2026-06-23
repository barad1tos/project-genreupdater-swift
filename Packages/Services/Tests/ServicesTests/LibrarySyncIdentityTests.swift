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

    @Test("Resolves prerelease pending when current status is unknown")
    func resolvesPrereleasePendingWhenCurrentStatusIsUnknown() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let pendingVerification = PendingVerificationProbe(entry: nil, isVerificationNeeded: false)
        let storedTrack = Track(
            id: "PRE",
            name: "Future Song",
            artist: "Daft Punk",
            album: "Future Album",
            trackStatus: TrackKind.prerelease.rawValue
        )
        let currentTrack = Track(
            id: "PRE",
            name: "Future Song",
            artist: "Daft Punk",
            album: "Future Album",
            trackStatus: nil
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
            removal.artist == "Daft Punk" && removal.album == "Future Album"
        })
    }

    @Test("Keeps unrelated pending row after prerelease transition")
    func keepsUnrelatedPendingRowAfterPrereleaseTransition() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let pendingVerification = PendingVerificationProbe(
            entry: PendingAlbumEntry(
                id: "pending",
                artist: "Daft Punk",
                album: "Random Access Memories",
                reason: "no_year_found"
            ),
            isVerificationNeeded: false
        )
        let storedTrack = Track(
            id: "PRE",
            name: "Get Lucky",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            trackStatus: TrackKind.prerelease.rawValue
        )
        let currentTrack = Track(
            id: "PRE",
            name: "Get Lucky",
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
        #expect(removedAlbums.isEmpty)
    }

    @Test("Keeps prerelease pending while a sibling album identity alias remains prerelease")
    func keepsPrereleasePendingWhileSiblingAlbumIdentityAliasRemainsPrerelease() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let pendingVerification = PendingVerificationProbe(entry: nil, isVerificationNeeded: false)
        let transitionedStoredTrack = Track(
            id: "PRE-1",
            name: "Get Lucky",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            trackStatus: TrackKind.prerelease.rawValue
        )
        let remainingStoredTrack = Track(
            id: "PRE-2",
            name: "Instant Crush",
            artist: "Daft Punk feat. Julian Casablancas",
            album: "Random Access Memories",
            trackStatus: TrackKind.prerelease.rawValue,
            albumArtist: "Daft Punk"
        )
        let transitionedCurrentTrack = Track(
            id: "PRE-1",
            name: "Get Lucky",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            trackStatus: TrackKind.subscription.rawValue
        )
        await bridge.setLibrary(ids: ["PRE-1", "PRE-2"], tracks: [
            "PRE-1": transitionedCurrentTrack,
            "PRE-2": remainingStoredTrack,
        ])
        await store.setStored([transitionedStoredTrack, remainingStoredTrack])
        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            pendingVerificationService: pendingVerification
        )

        _ = try await service.synchronizeNow(forceMetadataRefresh: true)

        let removedAlbums = await pendingVerification.removedAlbums
        #expect(removedAlbums.isEmpty)
    }

    @Test("Invalidates album identity caches for album artist changes and removals")
    func invalidatesAlbumIdentityCachesForAlbumArtistChangesAndRemovals() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let cache = MockCacheService()
        let snapshotService = SyncMockLibrarySnapshotService()
        let oldModified = Track(
            id: "MOD",
            name: "Guest Song",
            artist: "Guest Singer",
            album: "Shared Album",
            albumArtist: "Old Album Artist"
        )
        let newModified = Track(
            id: "MOD",
            name: "Guest Song",
            artist: "Guest Singer",
            album: "Shared Album",
            albumArtist: "New Album Artist"
        )
        let removed = Track(
            id: "REMOVED",
            name: "Removed Song",
            artist: "Guest Guitar",
            album: "Removed Album",
            albumArtist: "Removed Band"
        )
        await bridge.setLibrary(ids: ["MOD"], tracks: ["MOD": newModified])
        await store.setStored([oldModified, removed])
        await seedSyncCaches(cache, artist: "Old Album Artist", album: "Shared Album")
        await seedSyncCaches(cache, artist: "New Album Artist", album: "Shared Album")
        await seedSyncCaches(cache, artist: "Guest Singer", album: "Shared Album")
        await seedSyncCaches(cache, artist: "Removed Band", album: "Removed Album")
        await seedSyncCaches(cache, artist: "Guest Guitar", album: "Removed Album")
        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            cache: cache,
            librarySnapshotService: snapshotService
        )

        _ = try await service.synchronizeNow(forceMetadataRefresh: true)

        await expectSyncCachesInvalidated(cache, artist: "Old Album Artist", album: "Shared Album")
        await expectSyncCachesInvalidated(cache, artist: "New Album Artist", album: "Shared Album")
        await expectSyncCachesInvalidated(cache, artist: "Guest Singer", album: "Shared Album")
        await expectSyncCachesInvalidated(cache, artist: "Removed Band", album: "Removed Album")
        await expectSyncCachesInvalidated(cache, artist: "Guest Guitar", album: "Removed Album")
        #expect(await snapshotService.wasCleared())
    }
}
