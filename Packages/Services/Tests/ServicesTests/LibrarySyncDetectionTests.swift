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
            scriptBridge: bridge,
            trackStore: store
        )

        let result = try await service.detectChanges()
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
            scriptBridge: bridge,
            trackStore: store
        )

        let result = try await service.detectChanges()
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
            scriptBridge: bridge,
            trackStore: store
        )

        let result = try await service.detectChanges(forceMetadataRefresh: true)
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
            scriptBridge: bridge,
            trackStore: store
        )

        let result = try await service.detectChanges(forceMetadataRefresh: true)
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
        try await store.saveTracks([track])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store
        )

        let result = try await service.detectChanges(forceMetadataRefresh: true)
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
            scriptBridge: bridge,
            trackStore: store
        )

        let result = try await service.detectChanges(forceMetadataRefresh: true)
        #expect(result.modifiedTracks.count == 1)
        #expect(result.modifiedTracks.first?.id == "T1")
    }
}

@Suite("LibrarySyncService - runtime configuration")
struct LibrarySyncConfigTests {
    @Test("Uses configured AppleScript batch and timeout values")
    func usesConfiguredAppleScriptBatchAndTimeoutValues() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()

        let newTrack = Track(id: "NEW1", name: "New Song", artist: "Artist", album: "Album")
        await bridge.setLibrary(ids: ["NEW1"], tracks: ["NEW1": newTrack])
        await store.setStored([])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(
                idsBatchSize: 7,
                fullLibraryFetchTimeout: .seconds(11),
                idsBatchFetchTimeout: .seconds(13)
            )
        )

        _ = try await service.detectChanges()

        let fetchRequest = await bridge.lastFetchTracksRequest()
        #expect(await bridge.lastFetchAllTrackIDsTimeout() == .seconds(11))
        #expect(fetchRequest?.batchSize == 7)
        #expect(fetchRequest?.timeout == .seconds(13))
    }

    @Test("Runtime configuration update applies to subsequent sync")
    func runtimeConfigurationUpdateAppliesToSubsequentSync() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()

        let newTrack = Track(id: "NEW1", name: "New Song", artist: "Artist", album: "Album")
        await bridge.setLibrary(ids: ["NEW1"], tracks: ["NEW1": newTrack])
        await store.setStored([])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store
        )
        await service.updateRuntimeConfiguration(LibrarySyncRuntimeConfiguration(
            idsBatchSize: 3,
            fullLibraryFetchTimeout: .seconds(17),
            idsBatchFetchTimeout: .seconds(19)
        ))

        _ = try await service.detectChanges()

        let fetchRequest = await bridge.lastFetchTracksRequest()
        #expect(await bridge.lastFetchAllTrackIDsTimeout() == .seconds(17))
        #expect(fetchRequest?.batchSize == 3)
        #expect(fetchRequest?.timeout == .seconds(19))
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
            scriptBridge: bridge,
            trackStore: store
        )

        await #expect(throws: AppleScriptBridgeError.self) {
            _ = try await service.synchronizeNow()
        }
        #expect(try await store.trackCount() == 1)
    }
}
