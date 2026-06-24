import Testing
@testable import Core
@testable import Services

@Suite("Library sync album identity")
struct LibrarySyncIdentityTests {
    @Test("Resolves prerelease pending with album identity aliases")
    func resolvesPrereleasePendingWithAlbumIdentityAliases() async throws {
        let pendingVerification = PendingVerificationProbe(entries: [
            PendingAlbumEntry(
                id: "daft-punk",
                artist: "Daft Punk",
                album: "Random Access Memories",
                reason: "prerelease"
            ),
            PendingAlbumEntry(
                id: "daft-punk-feature",
                artist: "Daft Punk feat. Pharrell Williams",
                album: "Random Access Memories",
                reason: "prerelease"
            ),
        ], isVerificationNeeded: false)
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
        let service = await makePrereleaseSyncService(
            storedTracks: [storedTrack],
            currentTracks: ["PRE": currentTrack],
            pendingVerification: pendingVerification
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
        let pendingVerification = PendingVerificationProbe(
            entry: PendingAlbumEntry(
                id: "future",
                artist: "Daft Punk",
                album: "Future Album",
                reason: "prerelease"
            ),
            isVerificationNeeded: false
        )
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
        let service = await makePrereleaseSyncService(
            storedTracks: [storedTrack],
            currentTracks: ["PRE": currentTrack],
            pendingVerification: pendingVerification
        )

        _ = try await service.synchronizeNow(forceMetadataRefresh: true)

        let removedAlbums = await pendingVerification.removedAlbums
        #expect(removedAlbums.contains { removal in
            removal.artist == "Daft Punk" && removal.album == "Future Album"
        })
    }

    @Test("Keeps unrelated pending row after prerelease transition")
    func keepsUnrelatedPendingRowAfterPrereleaseTransition() async throws {
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
        let service = await makePrereleaseSyncService(
            storedTracks: [storedTrack],
            currentTracks: ["PRE": currentTrack],
            pendingVerification: pendingVerification
        )

        _ = try await service.synchronizeNow(forceMetadataRefresh: true)

        let removedAlbums = await pendingVerification.removedAlbums
        #expect(removedAlbums.isEmpty)
    }

    @Test("Removes resolved prerelease alias without touching unrelated pending alias")
    func removesResolvedPrereleaseAliasWithoutTouchingUnrelatedPendingAlias() async throws {
        let pendingVerification = PendingVerificationProbe(entries: [
            PendingAlbumEntry(
                id: "prerelease-alias",
                artist: "Daft Punk",
                album: "Random Access Memories",
                reason: "prerelease"
            ),
            PendingAlbumEntry(
                id: "year-alias",
                artist: "Daft Punk feat. Pharrell Williams",
                album: "Random Access Memories",
                reason: "no_year_found"
            ),
        ], isVerificationNeeded: false)
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
        let service = await makePrereleaseSyncService(
            storedTracks: [storedTrack],
            currentTracks: ["PRE": currentTrack],
            pendingVerification: pendingVerification
        )

        _ = try await service.synchronizeNow(forceMetadataRefresh: true)

        let removedAlbums = await pendingVerification.removedAlbums
        #expect(removedAlbums.contains { removal in
            removal.artist == "Daft Punk" && removal.album == "Random Access Memories"
        })
        #expect(!removedAlbums.contains { removal in
            removal.artist == "Daft Punk feat. Pharrell Williams" && removal.album == "Random Access Memories"
        })
    }

    @Test("Keeps prerelease pending while a sibling album identity alias remains prerelease")
    func keepsPrereleasePendingWhileSiblingAlbumIdentityAliasRemainsPrerelease() async throws {
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
        let service = await makePrereleaseSyncService(
            storedTracks: [transitionedStoredTrack, remainingStoredTrack],
            currentTracks: [
                "PRE-1": transitionedCurrentTrack,
                "PRE-2": remainingStoredTrack,
            ],
            pendingVerification: pendingVerification
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

    @Test("Persists identity-only changes and invalidates old and new caches")
    func persistsIdentityOnlyChangesAndInvalidatesOldAndNewCaches() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let cache = MockCacheService()
        let snapshotService = SyncMockLibrarySnapshotService()
        let storedTrack = Track(
            id: "IDENTITY",
            name: "Same Song",
            artist: "Old Artist",
            album: "Old Album",
            genre: "Rock",
            year: 2001
        )
        let currentTrack = Track(
            id: "IDENTITY",
            name: "Same Song",
            artist: "New Artist",
            album: "New Album",
            genre: "Rock",
            year: 2001
        )
        await bridge.setLibrary(ids: ["IDENTITY"], tracks: ["IDENTITY": currentTrack])
        await store.setStored([storedTrack])
        await seedSyncCaches(cache, artist: "Old Artist", album: "Old Album")
        await seedSyncCaches(cache, artist: "New Artist", album: "New Album")
        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            cache: cache,
            librarySnapshotService: snapshotService
        )

        let result = try await service.synchronizeNow(forceMetadataRefresh: true)
        let storedTracks = await store.storedTracks

        #expect(result.modifiedTracks.isEmpty)
        #expect(result.identityChangedTracks.map(\.id) == ["IDENTITY"])
        #expect(result.hasChanges)
        #expect(storedTracks.first { $0.id == "IDENTITY" }?.artist == "New Artist")
        #expect(storedTracks.first { $0.id == "IDENTITY" }?.album == "New Album")
        await expectSyncCachesInvalidated(cache, artist: "Old Artist", album: "Old Album")
        await expectSyncCachesInvalidated(cache, artist: "New Artist", album: "New Album")
        #expect(await snapshotService.wasCleared())
    }

    @Test("Display metadata changes refresh persisted tracks without API cache invalidation")
    func displayMetadataChangesRefreshPersistedTracksWithoutAPICacheInvalidation() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let cache = MockCacheService()
        let snapshotService = SyncMockLibrarySnapshotService()
        let storedTrack = Track(
            id: "DISPLAY",
            name: "Old Name",
            artist: "Same Artist",
            album: "Same Album",
            genre: "Rock",
            year: 2001,
            releaseYear: 1999
        )
        let currentTrack = Track(
            id: "DISPLAY",
            name: "New Name",
            artist: "Same Artist",
            album: "Same Album",
            genre: "Rock",
            year: 2001,
            releaseYear: 1999
        )
        await bridge.setLibrary(ids: ["DISPLAY"], tracks: ["DISPLAY": currentTrack])
        await store.setStored([storedTrack])
        await seedSyncCaches(cache, artist: "Same Artist", album: "Same Album")
        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            cache: cache,
            librarySnapshotService: snapshotService
        )

        let result = try await service.synchronizeNow(forceMetadataRefresh: true)
        let storedTracks = await store.storedTracks

        #expect(result.modifiedTracks.isEmpty)
        #expect(result.identityChangedTracks.isEmpty)
        #expect(result.refreshedTracks.map(\.id) == ["DISPLAY"])
        #expect(result.hasChanges)
        #expect(storedTracks.first { $0.id == "DISPLAY" }?.name == "New Name")
        await expectSyncCachesPreserved(cache, artist: "Same Artist", album: "Same Album")
        #expect(await snapshotService.wasCleared())
    }

    @Test("New tracks invalidate current album caches and clear snapshot")
    func newTracksInvalidateCurrentCachesAndClearSnapshot() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let cache = MockCacheService()
        let snapshotService = SyncMockLibrarySnapshotService()
        let newTrack = Track(
            id: "NEW",
            name: "New Song",
            artist: "New Artist",
            album: "New Album",
            genre: "Rock",
            year: 2001
        )
        await bridge.setLibrary(ids: ["NEW"], tracks: ["NEW": newTrack])
        await store.setStored([])
        await seedSyncCaches(cache, artist: "New Artist", album: "New Album")
        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            cache: cache,
            librarySnapshotService: snapshotService
        )

        let result = try await service.synchronizeNow(forceMetadataRefresh: true)
        let storedTracks = await store.storedTracks

        #expect(result.newTracks.map(\.id) == ["NEW"])
        #expect(result.modifiedTracks.isEmpty)
        #expect(result.identityChangedTracks.isEmpty)
        #expect(storedTracks.map(\.id) == ["NEW"])
        await expectSyncCachesInvalidated(cache, artist: "New Artist", album: "New Album")
        #expect(await snapshotService.wasCleared())
    }

    @Test("Managed metadata changes stay modified and invalidate current caches")
    func managedMetadataChangesStayModifiedAndInvalidateCurrentCaches() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let cache = MockCacheService()
        let snapshotService = SyncMockLibrarySnapshotService()
        let storedTrack = Track(
            id: "MOD",
            name: "Same Song",
            artist: "Same Artist",
            album: "Same Album",
            genre: "Rock",
            year: 2001
        )
        let currentTrack = Track(
            id: "MOD",
            name: "Same Song",
            artist: "Same Artist",
            album: "Same Album",
            genre: "Alternative",
            year: 2002
        )
        await bridge.setLibrary(ids: ["MOD"], tracks: ["MOD": currentTrack])
        await store.setStored([storedTrack])
        await seedSyncCaches(cache, artist: "Same Artist", album: "Same Album")
        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            cache: cache,
            librarySnapshotService: snapshotService
        )

        let result = try await service.synchronizeNow(forceMetadataRefresh: true)
        let storedTracks = await store.storedTracks

        #expect(result.modifiedTracks.map(\.id) == ["MOD"])
        #expect(result.identityChangedTracks.isEmpty)
        #expect(storedTracks.first { $0.id == "MOD" }?.genre == "Alternative")
        #expect(storedTracks.first { $0.id == "MOD" }?.year == 2002)
        await expectSyncCachesInvalidated(cache, artist: "Same Artist", album: "Same Album")
        #expect(await snapshotService.wasCleared())
    }

    @Test("Release year changes refresh persisted track metadata")
    func releaseYearChangesRefreshPersistedTrackMetadata() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let cache = MockCacheService()
        let snapshotService = SyncMockLibrarySnapshotService()
        let storedTrack = Track(
            id: "REL",
            name: "Same Song",
            artist: "Same Artist",
            album: "Same Album",
            genre: "Rock",
            year: 2001,
            releaseYear: 1999
        )
        let currentTrack = Track(
            id: "REL",
            name: "Same Song",
            artist: "Same Artist",
            album: "Same Album",
            genre: "Rock",
            year: 2001,
            releaseYear: 2005
        )
        await bridge.setLibrary(ids: ["REL"], tracks: ["REL": currentTrack])
        await store.setStored([storedTrack])
        await seedSyncCaches(cache, artist: "Same Artist", album: "Same Album")
        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            cache: cache,
            librarySnapshotService: snapshotService
        )

        let result = try await service.synchronizeNow(forceMetadataRefresh: true)
        let storedTracks = await store.storedTracks

        #expect(result.modifiedTracks.map(\.id) == ["REL"])
        #expect(result.identityChangedTracks.isEmpty)
        #expect(storedTracks.first { $0.id == "REL" }?.releaseYear == 2005)
        await expectSyncCachesInvalidated(cache, artist: "Same Artist", album: "Same Album")
        #expect(await snapshotService.wasCleared())
    }

    @Test("Managed metadata and album identity changes invalidate old and new caches")
    func managedMetadataAndAlbumIdentityChangesInvalidateOldAndNewCaches() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let cache = MockCacheService()
        let snapshotService = SyncMockLibrarySnapshotService()
        let storedTrack = Track(
            id: "BOTH",
            name: "Same Song",
            artist: "Old Artist",
            album: "Old Album",
            genre: "Rock",
            year: 2001
        )
        let currentTrack = Track(
            id: "BOTH",
            name: "Same Song",
            artist: "New Artist",
            album: "New Album",
            genre: "Alternative",
            year: 2002
        )
        await bridge.setLibrary(ids: ["BOTH"], tracks: ["BOTH": currentTrack])
        await store.setStored([storedTrack])
        await seedSyncCaches(cache, artist: "Old Artist", album: "Old Album")
        await seedSyncCaches(cache, artist: "New Artist", album: "New Album")
        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            cache: cache,
            librarySnapshotService: snapshotService
        )

        let result = try await service.synchronizeNow(forceMetadataRefresh: true)
        let storedTracks = await store.storedTracks

        #expect(result.modifiedTracks.map(\.id) == ["BOTH"])
        #expect(result.identityChangedTracks.isEmpty)
        #expect(storedTracks.first { $0.id == "BOTH" }?.artist == "New Artist")
        #expect(storedTracks.first { $0.id == "BOTH" }?.album == "New Album")
        await expectSyncCachesInvalidated(cache, artist: "Old Artist", album: "Old Album")
        await expectSyncCachesInvalidated(cache, artist: "New Artist", album: "New Album")
        #expect(await snapshotService.wasCleared())
    }

    private func makePrereleaseSyncService(
        storedTracks: [Track],
        currentTracks: [String: Track],
        pendingVerification: PendingVerificationProbe
    ) async -> LibrarySyncService {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        await bridge.setLibrary(ids: currentTracks.keys.sorted(), tracks: currentTracks)
        await store.setStored(storedTracks)
        return LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            pendingVerificationService: pendingVerification
        )
    }
}
