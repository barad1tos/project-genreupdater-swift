import Testing
@testable import Core
@testable import Services

@Suite("Library sync scope evidence")
struct LibrarySyncCoverageTests {
    @Test("A completed artist sync cannot authorize a later full-library request")
    func scopeDoesNotCoverLibrary() async throws {
        let observer = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        await observer.setLibrary(ids: ["metallica", "bjork"], tracks: [
            "metallica": track(id: "metallica", artist: "Metallica"),
            "bjork": track(id: "bjork", artist: "Björk"),
        ])
        let service = LibrarySyncService(
            trackStore: store,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(testArtists: ["Metallica"]),
            observer: observer
        )

        _ = try await service.synchronizeNow(forceMetadataRefresh: true)
        #expect(await store.mirrorCoverage() == .verified(MirrorScope(testArtists: ["Metallica"])))

        await service.updateRuntimeConfiguration(LibrarySyncRuntimeConfiguration(testArtists: []))
        _ = try await service.synchronizeNow()

        let requests = await observer.recordedObservationRequests()
        let fullLibraryRequest = try #require(requests.last)
        if case .initial = fullLibraryRequest.previous {
            // Expected: artist-scoped evidence cannot seed the full-library observation.
        } else {
            Issue.record("Expected a full-library observation without reused artist-scoped evidence")
        }
        #expect(await store.mirrorCoverage() == .verified(.fullLibrary))
    }

    @Test("Incomplete metadata invalidates prior full-library evidence")
    func metadataGapInvalidates() async throws {
        let observer = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        await store.setStored([track(id: "metallica", artist: "Metallica")])
        await observer.setLibrary(ids: ["metallica"], tracks: [:])
        let service = LibrarySyncService(trackStore: store, observer: observer)

        _ = try await service.synchronizeNow(forceMetadataRefresh: true)

        #expect(await store.mirrorCoverage() == .unknown)
    }

    @Test("Incomplete scoped membership invalidates prior artist evidence")
    func membershipGapInvalidates() async throws {
        let observer = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let scope = MirrorScope(testArtists: ["Metallica"])
        await store.setStored([track(id: "metallica", artist: "Metallica")])
        await store.setMirrorCoverage(.verified(scope))
        await observer.setLibrary(ids: ["metallica"], tracks: [:])
        let service = LibrarySyncService(
            trackStore: store,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(testArtists: scope.testArtists),
            observer: observer
        )

        _ = try await service.synchronizeNow(forceMetadataRefresh: true)

        #expect(await store.mirrorCoverage() == .unknown)
    }

    @Test("Album-targeted synchronization invalidates prior evidence")
    func albumTargetInvalidates() async throws {
        let observer = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        await store.setStored([track(id: "metallica", artist: "Metallica")])
        await observer.setLibrary(ids: ["metallica"], tracks: [
            "metallica": track(id: "metallica", artist: "Metallica"),
        ])
        let service = LibrarySyncService(
            trackStore: store,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(
                albumTargetIdentity: AlbumIdentity(artist: "Metallica", album: "Album")
            ),
            observer: observer
        )

        _ = try await service.synchronizeNow(forceMetadataRefresh: true)

        #expect(await store.mirrorCoverage() == .unknown)
    }

    private func track(id: String, artist: String) -> Track {
        Track(id: id, name: "Song", artist: artist, album: "Album", appleScriptID: id)
    }
}
