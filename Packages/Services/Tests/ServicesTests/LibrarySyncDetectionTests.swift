import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("LibrarySyncService - library change detection")
struct LibrarySyncDetectionTests {
    @Test("Detect new tracks in library")
    func detectNewTracks() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()

        let newTrack = Track(id: "NEW1", name: "New Song", artist: "Artist", album: "Album")
        await bridge.setLibrary(ids: ["T1", "NEW1"], tracks: [
            "T1": Track(id: "T1", name: "Existing", artist: "A", album: "B"),
            "NEW1": newTrack
        ])
        await store.setStored([
            Track(id: "T1", name: "Existing", artist: "A", album: "B")
        ])

        let service = LibrarySyncService(
            trackStore: store,
            observer: bridge
        )

        let result = try await service.detectObservation().result
        #expect(result.newTracks.count == 1)
        #expect(result.newTracks.first?.id == "NEW1")
        #expect(result.removedTrackIDs.isEmpty)
    }

    @Test("Detect removed tracks")
    func detectRemovedTracks() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()

        await bridge.setLibrary(ids: ["T1"], tracks: [
            "T1": Track(id: "T1", name: "Stays", artist: "A", album: "B")
        ])
        await store.setStored([
            Track(id: "T1", name: "Stays", artist: "A", album: "B"),
            Track(id: "T2", name: "Removed", artist: "A", album: "B")
        ])

        let service = LibrarySyncService(
            trackStore: store,
            observer: bridge
        )

        let result = try await service.detectObservation().result
        #expect(result.newTracks.isEmpty)
        #expect(result.removedTrackIDs == ["T2"])
    }

    @Test("Ignore timestamp-only metadata churn during force scan")
    func ignoreTimestampOnlyMetadataChurnDuringForceScan() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()

        let oldDate = Date().addingTimeInterval(-3600)
        let newDate = Date()

        await bridge.setLibrary(ids: ["T1"], tracks: [
            "T1": Track(
                id: "T1",
                name: "Track",
                artist: "A",
                album: "B",
                genre: "Rock",
                year: 2001,
                dateAdded: newDate,
                lastModified: newDate,
                trackStatus: "matched"
            )
        ])
        await store.setStored([
            Track(
                id: "T1",
                name: "Track",
                artist: "A",
                album: "B",
                genre: "Rock",
                year: 2001,
                dateAdded: oldDate,
                lastModified: oldDate,
                trackStatus: "matched"
            )
        ])

        let service = LibrarySyncService(
            trackStore: store,
            observer: bridge
        )

        let result = try await service.detectObservation(forceMetadataRefresh: true).result
        #expect(result.modifiedTracks.isEmpty)
    }

    @Test("Ignore newly populated track status during force scan")
    func ignoreNewlyPopulatedTrackStatusDuringForceScan() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()

        await bridge.setLibrary(ids: ["T1"], tracks: [
            "T1": Track(
                id: "T1",
                name: "Track",
                artist: "A",
                album: "B",
                genre: "Rock",
                year: 2001,
                trackStatus: "matched"
            )
        ])
        await store.setStored([
            Track(
                id: "T1",
                name: "Track",
                artist: "A",
                album: "B",
                genre: "Rock",
                year: 2001
            )
        ])

        let service = LibrarySyncService(
            trackStore: store,
            observer: bridge
        )

        let result = try await service.detectObservation(forceMetadataRefresh: true).result
        #expect(result.modifiedTracks.isEmpty)
    }

    @Test("Persisted release metadata does not repeat force-scan deltas")
    func persistedReleaseMetadataDoesNotRepeatForceScanDeltas() async throws {
        let bridge = SyncMockScriptClient()
        let store = try TrackDataStore.createInMemory()
        let track = Track(
            id: "T1",
            name: "Track",
            artist: "A",
            album: "B",
            genre: "Rock",
            year: 2001,
            trackStatus: "matched",
            releaseYear: 2001
        )

        await bridge.setLibrary(ids: ["T1"], tracks: ["T1": track])
        try await store.seedMirror([track])

        let service = LibrarySyncService(
            trackStore: store,
            observer: bridge
        )

        let result = try await service.detectObservation(forceMetadataRefresh: true).result
        #expect(result.modifiedTracks.isEmpty)
    }

    @Test("Detect modified tracks by processing metadata even when lastModified is older")
    func detectModifiedTracksByProcessingMetadataWhenLastModifiedIsOlder() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let storedDate = Date()
        let currentDate = storedDate.addingTimeInterval(-3600)

        await bridge.setLibrary(ids: ["T1"], tracks: [
            "T1": Track(
                id: "T1",
                name: "Track",
                artist: "A",
                album: "B",
                genre: "Stoner Rock",
                year: 2001,
                lastModified: currentDate,
                trackStatus: "matched"
            )
        ])
        await store.setStored([
            Track(
                id: "T1",
                name: "Track",
                artist: "A",
                album: "B",
                genre: "Rock",
                year: 1999,
                lastModified: storedDate,
                trackStatus: "uploaded"
            )
        ])

        let service = LibrarySyncService(
            trackStore: store,
            observer: bridge
        )

        let result = try await service.detectObservation(forceMetadataRefresh: true).result
        #expect(result.modifiedTracks.count == 1)
        #expect(result.modifiedTracks.first?.id == "T1")
    }
}

@Suite("LibrarySyncService - runtime configuration")
struct LibrarySyncConfigTests {
    @Test("Fast sync requests an initial observation and returns its new track")
    func requestsInitialFastObservation() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()

        let newTrack = Track(id: "NEW1", name: "New Song", artist: "Artist", album: "Album")
        await bridge.setLibrary(ids: ["NEW1"], tracks: ["NEW1": newTrack])

        let service = LibrarySyncService(
            trackStore: store,
            observer: bridge
        )

        let result = try await service.detectObservation().result

        let request = try #require(await bridge.recordedObservationRequests().first)
        #expect(request.refresh == .fast)
        #expect(request.previous == .initial)
        #expect(result.newTracks.map(\.id) == ["NEW1"])
    }

    @Test("Runtime scope update applies to the next observation")
    func runtimeScopeUpdateAppliesToNextObservation() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()

        let target = Track(id: "TARGET", name: "Target Song", artist: "Target", album: "Album")
        let outside = Track(id: "OUTSIDE", name: "Other Song", artist: "Other", album: "Album")
        await bridge.setLibrary(ids: ["TARGET", "OUTSIDE"], tracks: [
            "TARGET": target,
            "OUTSIDE": outside,
        ])
        await store.setStored([])

        let service = LibrarySyncService(
            trackStore: store,
            observer: bridge
        )
        await service.updateRuntimeConfiguration(LibrarySyncRuntimeConfiguration(testArtists: ["Target"]))

        let result = try await service.detectObservation().result

        let request = try #require(await bridge.recordedObservationRequests().first)
        #expect(request.scope.source == .testArtists)
        #expect(request.scope.normalizedTestArtists == ["Target"])
        #expect(result.newTracks.map(\.id) == ["TARGET"])
    }

    @Test("Track ID fetch failure does not apply removals")
    func trackIDFetchFailureDoesNotApplyRemovals() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        await bridge.setFetchAllTrackIDsError(.executionFailed(
            scriptName: "fetch_track_ids",
            detail: "ERROR:Music failed"
        ))
        await store.setStored([
            Track(id: "T1", name: "Stored", artist: "A", album: "B")
        ])

        let service = LibrarySyncService(
            trackStore: store,
            observer: bridge
        )

        await #expect(throws: AppleScriptBridgeError.self) {
            _ = try await service.synchronizeNow()
        }
        #expect(try await store.trackCount() == 1)
    }
}
