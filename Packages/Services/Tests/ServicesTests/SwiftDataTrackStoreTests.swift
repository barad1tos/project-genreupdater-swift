import Foundation
import SwiftData
import Testing
@testable import Core
@testable import Services

@Suite("SwiftDataTrackStore — Phase 2A")
struct SwiftDataTrackStoreTests {
    /// Create an in-memory SwiftDataTrackStore for testing.
    private func makeStore() throws -> SwiftDataTrackStore {
        try SwiftDataTrackStore.createInMemory()
    }

    private func sampleTrack(id: String = "T001", name: String = "Test Song") -> Track {
        Track(
            id: id,
            name: name,
            artist: "Test Artist",
            album: "Test Album",
            genre: "Rock",
            year: 2020,
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - Initialization

    @Test("Store initializes without error")
    func initializeSucceeds() async throws {
        let store = try makeStore()
        try await store.initialize()
    }

    // MARK: - Save and Load

    @Test("Save and load tracks roundtrip")
    func saveAndLoadRoundtrip() async throws {
        let store = try makeStore()
        try await store.initialize()

        let tracks = [sampleTrack(id: "1"), sampleTrack(id: "2", name: "Another Song")]
        try await store.saveTracks(tracks)

        let loaded = try await store.loadAllTracks()
        #expect(loaded.count == 2)
    }

    @Test("getTrack by ID returns correct track")
    func getTrackByID() async throws {
        let store = try makeStore()
        try await store.initialize()

        try await store.saveTracks([sampleTrack(id: "ABC")])

        let found = try await store.getTrack(byID: "ABC")
        #expect(found != nil)
        #expect(found?.id == "ABC")
        #expect(found?.name == "Test Song")
    }

    @Test("getTrack returns nil for missing ID")
    func getTrackMissing() async throws {
        let store = try makeStore()
        try await store.initialize()

        let found = try await store.getTrack(byID: "NONEXISTENT")
        #expect(found == nil)
    }

    // MARK: - Track Count

    @Test("trackCount returns correct count")
    func trackCountAccuracy() async throws {
        let store = try makeStore()
        try await store.initialize()

        #expect(try await store.trackCount() == 0)

        try await store.saveTracks([sampleTrack(id: "1"), sampleTrack(id: "2"), sampleTrack(id: "3")])
        #expect(try await store.trackCount() == 3)
    }

    @Test("deleteTrackIDs removes persisted tracks")
    func deleteTrackIDs() async throws {
        let store = try makeStore()
        try await store.initialize()

        try await store.saveTracks([
            sampleTrack(id: "1"),
            sampleTrack(id: "2"),
            sampleTrack(id: "3"),
        ])

        let deletedCount = try await store.deleteTrackIDs(["2", "missing"])
        let remainingTracks = try await store.loadAllTracks()
        let remainingIDs = remainingTracks.map(\.id).sorted()

        #expect(deletedCount == 1)
        #expect(remainingIDs == ["1", "3"])
    }

    // MARK: - Upsert

    @Test("saveTracks updates existing tracks")
    func upsertBehavior() async throws {
        let store = try makeStore()
        try await store.initialize()

        let original = Track(id: "U1", name: "Original", artist: "A", album: "B")
        try await store.saveTracks([original])

        let updated = Track(id: "U1", name: "Updated", artist: "A", album: "B", genre: "Metal")
        try await store.saveTracks([updated])

        let count = try await store.trackCount()
        #expect(count == 1)

        let track = try await store.getTrack(byID: "U1")
        #expect(track?.name == "Updated")
        #expect(track?.genre == "Metal")
    }

    // MARK: - Processing State

    @Test("updateTrackProcessingState sets flags")
    func updateProcessingState() async throws {
        let store = try makeStore()
        try await store.initialize()

        try await store.saveTracks([sampleTrack(id: "PS1")])
        try await store.updateTrackProcessingState(id: "PS1", genreUpdated: true, yearUpdated: nil)

        let unprocessed = try await store.getUnprocessedTracks()
        // genreUpdated=true, yearUpdated=false → still unprocessed
        #expect(unprocessed.count == 1)

        try await store.updateTrackProcessingState(id: "PS1", genreUpdated: nil, yearUpdated: true)
        let stillUnprocessed = try await store.getUnprocessedTracks()
        #expect(stillUnprocessed.isEmpty)
    }

    @Test("getUnprocessedTracks filters correctly")
    func unprocessedTracksFilter() async throws {
        let store = try makeStore()
        try await store.initialize()

        try await store.saveTracks([
            sampleTrack(id: "P1"),
            sampleTrack(id: "P2"),
            sampleTrack(id: "P3"),
        ])

        // Mark P1 as fully processed
        try await store.updateTrackProcessingState(id: "P1", genreUpdated: true, yearUpdated: true)

        let unprocessed = try await store.getUnprocessedTracks()
        #expect(unprocessed.count == 2)
        #expect(!unprocessed.contains { $0.id == "P1" })
    }

    // MARK: - Batch Operations

    @Test("Large batch save works (simulating chunked inserts)")
    func largeBatchSave() async throws {
        let store = try makeStore()
        try await store.initialize()

        let tracks = (0 ..< 600).map { index in
            Track(
                id: "BATCH\(index)",
                name: "Track \(index)",
                artist: "Artist",
                album: "Album"
            )
        }

        try await store.saveTracks(tracks)
        let count = try await store.trackCount()
        #expect(count == 600)
    }

    @Test("updateTrackProcessingState ignores missing track")
    func updateMissingTrack() async throws {
        let store = try makeStore()
        try await store.initialize()

        // Should not throw
        try await store.updateTrackProcessingState(id: "MISSING", genreUpdated: true, yearUpdated: true)
    }
}
