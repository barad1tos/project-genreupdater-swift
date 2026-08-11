import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("LibrarySyncService - read-provider mutation metadata")
struct LibrarySyncMutationTests {
    @Test("Read provider force scan ignores missing MusicKit mutation metadata")
    func readProviderForceScanIgnoresMissingMusicKitMutationMetadata() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let readProvider = SyncMockReadProvider()

        await readProvider.setTracks([
            Track(id: "MK-1", name: "Existing", artist: "A", album: "B")
        ])
        await store.setStored([
            Track(
                id: "MK-1",
                name: "Existing",
                artist: "A",
                album: "B",
                genre: "Metal",
                year: 1986,
                appleScriptID: "AS-1"
            )
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            readProvider: readProvider
        )

        let result = try await service.detectChanges(forceMetadataRefresh: true)

        #expect(result.modifiedTracks.isEmpty)
        #expect(result.identityChangedTracks.isEmpty)
        #expect(result.refreshedTracks.isEmpty)
        #expect(await bridge.fetchAllTrackIDsCallCount() == 0)
    }

    @Test("Read provider removal resolution preserves partial AppleScript metadata")
    func readProviderRemovalResolutionPreservesPartialAppleScriptMetadata() async {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store
        )
        let storedTrack = Track(
            id: "MK-1",
            name: "Existing",
            artist: "A",
            album: "B",
            genre: "Metal",
            year: 1986,
            releaseYear: 1986,
            albumArtist: "Metallica",
            appleScriptID: nil
        )
        let partialMetadataTrack = Track(
            id: "MK-1",
            name: "Existing",
            artist: "A",
            album: "B",
            appleScriptID: "AS-1"
        )

        let persistedTrack = await service.readProviderPersistenceTrack(
            current: partialMetadataTrack,
            stored: storedTrack,
            appleScriptMetadata: partialMetadataTrack
        )

        #expect(persistedTrack.genre == "Metal")
        #expect(persistedTrack.year == 1986)
        #expect(persistedTrack.releaseYear == 1986)
        #expect(persistedTrack.albumArtist == "Metallica")
        #expect(persistedTrack.appleScriptID == "AS-1")
    }

    @Test("Read provider force scan refreshes AppleScript mutation metadata")
    func readProviderForceScanRefreshesAppleScriptMutationMetadata() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let readProvider = SyncMockReadProvider()

        await readProvider.setTracks([
            Track(id: "MK-1", name: "Existing", artist: "A", album: "B")
        ])
        await bridge.setLibrary(ids: ["AS-1"], tracks: [
            "AS-1": Track(
                id: "AS-1",
                name: "Existing",
                artist: "A",
                album: "B",
                genre: "Thrash Metal",
                year: 1988,
                trackStatus: TrackKind.localOnly.rawValue,
                releaseYear: 1988,
                appleScriptID: "AS-1"
            )
        ])
        await store.setStored([
            Track(
                id: "MK-1",
                name: "Existing",
                artist: "A",
                album: "B",
                genre: "Metal",
                year: 1986,
                trackStatus: TrackKind.localOnly.rawValue,
                releaseYear: 1986,
                appleScriptID: "AS-1"
            )
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            readProvider: readProvider
        )

        let result = try await service.synchronizeNow(forceMetadataRefresh: true)
        let storedTrack = try #require(await store.getTrack(byID: "MK-1"))

        #expect(result.modifiedTracks.map(\.id) == ["MK-1"])
        #expect(storedTrack.genre == "Thrash Metal")
        #expect(storedTrack.year == 1988)
        #expect(storedTrack.releaseYear == 1988)
        #expect(await bridge.fetchTracksRequestCount() == 1)
    }

    @Test("Read provider force scan preserves cleared AppleScript mutation metadata")
    func readProviderForceScanPreservesClearedAppleScriptMutationMetadata() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let readProvider = SyncMockReadProvider()

        await readProvider.setTracks([
            Track(
                id: "MK-1",
                name: "Existing",
                artist: "A",
                album: "B",
                genre: "MusicKit Genre",
                releaseYear: 2024,
                albumArtist: "MusicKit Album Artist"
            )
        ])
        await bridge.setLibrary(ids: ["AS-1"], tracks: [
            "AS-1": Track(
                id: "AS-1",
                name: "Existing",
                artist: "A",
                album: "B",
                appleScriptID: "AS-1"
            )
        ])
        await store.setStored([
            Track(
                id: "MK-1",
                name: "Existing",
                artist: "A",
                album: "B",
                genre: "Metal",
                year: 1986,
                releaseYear: 1986,
                albumArtist: "Metallica",
                appleScriptID: "AS-1"
            )
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            readProvider: readProvider
        )

        let result = try await service.synchronizeNow(forceMetadataRefresh: true)
        let storedTrack = try #require(await store.getTrack(byID: "MK-1"))

        #expect(result.modifiedTracks.map(\.id) == ["MK-1"])
        #expect(storedTrack.genre == nil)
        #expect(storedTrack.year == nil)
        #expect(storedTrack.releaseYear == nil)
        #expect(storedTrack.albumArtist == nil)
        #expect(storedTrack.appleScriptID == "AS-1")
        #expect(await bridge.fetchTracksRequestCount() == 1)
    }
}

@Suite("LibrarySyncService - read-provider enrichment")
struct LibrarySyncEnrichmentTests {
    @Test("Read provider sync verifies stored prerelease availability through AppleScript")
    func readProviderSyncVerifiesStoredPrereleaseAvailabilityThroughAppleScript() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let readProvider = SyncMockReadProvider()

        await readProvider.setTracks([
            Track(id: "MK-1", name: "Future Track", artist: "Artist", album: "Future Album")
        ])
        await bridge.setLibrary(ids: ["AS-1"], tracks: [
            "AS-1": Track(
                id: "AS-1",
                name: "Future Track",
                artist: "Artist",
                album: "Future Album",
                trackStatus: TrackKind.subscription.rawValue,
                appleScriptID: "AS-1"
            )
        ])
        await store.setStored([
            Track(
                id: "MK-1",
                name: "Future Track",
                artist: "Artist",
                album: "Future Album",
                trackStatus: TrackKind.prerelease.rawValue,
                appleScriptID: "AS-1"
            )
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            readProvider: readProvider
        )

        let result = try await service.synchronizeNow(forceMetadataRefresh: true)
        let storedTrack = try #require(await store.getTrack(byID: "MK-1"))

        #expect(result.modifiedTracks.map(\.id) == ["MK-1"])
        #expect(storedTrack.trackStatus == TrackKind.subscription.rawValue)
        #expect(storedTrack.appleScriptID == "AS-1")
        #expect(await bridge.fetchAllTrackIDsCallCount() == 0)
        #expect(await bridge.fetchTracksRequestCount() == 1)
    }

    @Test("Read provider refresh preserves AppleScript enrichment metadata")
    func readProviderRefreshPreservesAppleScriptEnrichmentMetadata() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let readProvider = SyncMockReadProvider()

        await readProvider.setTracks([
            Track(
                id: "MK-1",
                name: "Renamed",
                artist: "A",
                album: "B",
                genre: "MusicKit Genre",
                releaseYear: 2024,
                albumArtist: "MusicKit Album Artist"
            )
        ])
        await store.setStored([
            Track(
                id: "MK-1",
                name: "Original",
                artist: "A",
                album: "B",
                genre: "Metal",
                year: 1986,
                dateAdded: Date(timeIntervalSince1970: 100),
                lastModified: Date(timeIntervalSince1970: 200),
                trackStatus: "local only",
                releaseYear: 1986,
                albumArtist: "Metallica",
                appleScriptID: "AS-1"
            )
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            readProvider: readProvider
        )

        let result = try await service.synchronizeNow(forceMetadataRefresh: true)
        let storedTrack = try #require(await store.getTrack(byID: "MK-1"))

        #expect(result.refreshedTracks.map(\.id) == ["MK-1"])
        #expect(storedTrack.name == "Renamed")
        #expect(storedTrack.appleScriptID == "AS-1")
        #expect(storedTrack.genre == "Metal")
        #expect(storedTrack.year == 1986)
        #expect(storedTrack.trackStatus == "local only")
        #expect(storedTrack.releaseYear == 1986)
        #expect(storedTrack.albumArtist == "Metallica")
        #expect(storedTrack.lastModified == Date(timeIntervalSince1970: 200))
        #expect(await bridge.fetchAllTrackIDsCallCount() == 0)
    }
}
