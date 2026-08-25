import Foundation
import Testing
@testable import Core
@testable import Services

private struct PrereleaseFixture {
    let store: SyncMockTrackStore
    let pendingVerification: PendingVerificationProbe
    let service: LibrarySyncService
}

@Suite("LibrarySyncService - applying detected changes")
struct LibrarySyncApplyTests {
    @Test("No changes detected returns empty result")
    func noChanges() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()

        let track = Track(id: "T1", name: "Track", artist: "A", album: "B")
        await bridge.setLibrary(ids: ["T1"], tracks: ["T1": track])
        await store.setStored([track])

        let service = LibrarySyncService(
            trackStore: store,
            observer: bridge
        )

        let result = try await service.detectObservation().result
        #expect(!result.hasChanges)
    }

    @Test("Synchronize now applies new modified and removed tracks to store")
    func synchronizeNowAppliesDetectedChanges() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let modifiedDate = Date()

        let newTrack = Track(id: "NEW", name: "New Song", artist: "Artist", album: "Album")
        let modifiedTrack = Track(
            id: "MOD",
            name: "Song",
            artist: "Artist",
            album: "Album",
            genre: "Alternative",
            year: 2024,
            lastModified: modifiedDate
        )

        await bridge.setLibrary(ids: ["NEW", "MOD"], tracks: [
            "NEW": newTrack,
            "MOD": modifiedTrack
        ])
        await store.setStored([
            Track(
                id: "MOD",
                name: "Song",
                artist: "Artist",
                album: "Album",
                genre: "Rock",
                year: 2001,
                lastModified: modifiedDate
            ),
            Track(id: "REMOVED", name: "Removed Song", artist: "Artist", album: "Album")
        ])

        let service = LibrarySyncService(
            trackStore: store,
            observer: bridge
        )

        let result = try await service.synchronizeNow(forceMetadataRefresh: true)
        let storedTracks = await store.storedTracks

        #expect(result.newTracks.map(\.id) == ["NEW"])
        #expect(result.modifiedTracks.map(\.id) == ["MOD"])
        #expect(result.removedTrackIDs == ["REMOVED"])
        #expect(storedTracks.map(\.id).sorted() == ["MOD", "NEW"])
        #expect(storedTracks.first { $0.id == "MOD" }?.genre == "Alternative")
        #expect(storedTracks.first { $0.id == "MOD" }?.year == 2024)
    }

    @Test("Synchronize now resolves prerelease pending after subscription transition")
    func synchronizeNowResolvesPrereleasePendingAfterSubscriptionTransition() async throws {
        let fixture = await makePrereleaseFixture(currentStatus: .subscription)

        let result = try await fixture.service.synchronizeNow(forceMetadataRefresh: true)
        let storedTracks = await fixture.store.storedTracks
        let removedAlbums = await fixture.pendingVerification.removedAlbums
        let removedAlbum = try #require(removedAlbums.first)
        let modifiedTrackIDs: [String] = result.modifiedTracks.map(\.id)

        #expect(modifiedTrackIDs == ["PRE"])
        #expect(storedTracks.first { $0.id == "PRE" }?.trackStatus == TrackKind.subscription.rawValue)
        #expect(removedAlbums.count == 1)
        #expect(removedAlbum.artist == "SubRosa")
        #expect(removedAlbum.album == "Future Album")
    }

    @Test("Synchronize now keeps prerelease pending after unavailable transition")
    func synchronizeNowKeepsPrereleasePendingAfterUnavailableTransition() async throws {
        let fixture = await makePrereleaseFixture(currentStatus: .noLongerAvailable)

        let result = try await fixture.service.synchronizeNow(forceMetadataRefresh: true)
        let storedTracks = await fixture.store.storedTracks
        let removedAlbums = await fixture.pendingVerification.removedAlbums
        let modifiedTrackIDs: [String] = result.modifiedTracks.map(\.id)

        #expect(modifiedTrackIDs == ["PRE"])
        #expect(storedTracks.first { $0.id == "PRE" }?.trackStatus == TrackKind.noLongerAvailable.rawValue)
        #expect(removedAlbums.isEmpty)
    }

    @Test("Synchronize now invalidates cache for modified identities and removed tracks")
    func synchronizeNowInvalidatesCacheForModifiedIdentitiesAndRemovedTracks() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let cache = MockCacheService()
        let snapshotService = SyncMockLibrarySnapshotService()

        let oldModified = Track(id: "MOD", name: "Song", artist: "Old Artist", album: "Old Album")
        let newModified = Track(id: "MOD", name: "Song", artist: "New Artist", album: "New Album")
        let removed = Track(id: "REMOVED", name: "Removed", artist: "Gone Artist", album: "Gone Album")
        await bridge.setLibrary(ids: ["MOD"], tracks: ["MOD": newModified])
        await store.setStored([oldModified, removed])
        await seedSyncCaches(cache, artist: "Old Artist", album: "Old Album")
        await seedSyncCaches(cache, artist: "New Artist", album: "New Album")
        await seedSyncCaches(cache, artist: "Gone Artist", album: "Gone Album")

        let service = LibrarySyncService(
            trackStore: store,
            cache: cache,
            librarySnapshotService: snapshotService,
            observer: bridge
        )

        _ = try await service.synchronizeNow(forceMetadataRefresh: true)

        await expectSyncCachesInvalidated(cache, artist: "Old Artist", album: "Old Album")
        await expectSyncCachesInvalidated(cache, artist: "New Artist", album: "New Album")
        await expectSyncCachesInvalidated(cache, artist: "Gone Artist", album: "Gone Album")
        let wasCleared = await snapshotService.wasCleared()
        #expect(wasCleared)
    }

    private func makePrereleaseFixture(currentStatus: TrackKind) async -> PrereleaseFixture {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let pendingVerification = PendingVerificationProbe(
            entry: PendingAlbumEntry(
                id: "subrosa-future-album",
                artist: "SubRosa",
                album: "Future Album",
                reason: "prerelease"
            ),
            isVerificationNeeded: false
        )
        let modifiedDate = Date()
        let storedTrack = Track(
            id: "PRE",
            name: "Future Song",
            artist: "SubRosa",
            album: "Future Album",
            lastModified: modifiedDate,
            trackStatus: TrackKind.prerelease.rawValue
        )
        let currentTrack = Track(
            id: "PRE",
            name: "Future Song",
            artist: "SubRosa",
            album: "Future Album",
            lastModified: modifiedDate,
            trackStatus: currentStatus.rawValue
        )
        await bridge.setLibrary(ids: ["PRE"], tracks: ["PRE": currentTrack])
        await store.setStored([storedTrack])

        let service = LibrarySyncService(
            trackStore: store,
            pendingVerificationService: pendingVerification,
            observer: bridge
        )
        return PrereleaseFixture(
            store: store,
            pendingVerification: pendingVerification,
            service: service
        )
    }
}
