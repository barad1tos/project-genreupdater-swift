import Foundation
import SwiftData
import Testing
@testable import Core
@testable import Services

@Suite("TrackDataStore — Phase 2A")
struct TrackDataTests {
    /// Create an in-memory TrackDataStore for testing.
    private func makeStore() throws -> TrackDataStore {
        try TrackDataStore.createInMemory()
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

    private func appliedChange(
        trackID: String = "T001",
        type: ChangeType
    ) -> ChangeLogEntry {
        var change = ChangeLogEntry(
            changeType: type,
            trackID: trackID,
            artist: "Test Artist",
            trackName: "Test Song",
            albumName: "Test Album"
        )
        switch type {
        case .genreUpdate:
            change.oldGenre = "Rock"
            change.newGenre = "Metal"
        case .yearUpdate:
            change.oldYear = 2020
            change.newYear = 2024
        case .yearRevert:
            change.oldYear = 2020
            change.newYear = 1999
        case .trackCleaning:
            change.oldTrackName = "Test Song"
            change.newTrackName = "Clean Song"
        case .albumCleaning:
            change.oldAlbumName = "Test Album"
            change.newAlbumName = "Clean Album"
        case .artistRename:
            change.oldArtist = "Test Artist"
            change.newArtist = "Canonical Artist"
        }
        return change
    }

    private struct AppliedChangeExpectation {
        let type: ChangeType
        let name: String
        let artist: String
        let album: String
        let genre: String
        let year: Int
    }

    private var appliedChangeExpectations: [AppliedChangeExpectation] {
        [
            AppliedChangeExpectation(
                type: .genreUpdate,
                name: "Test Song",
                artist: "Test Artist",
                album: "Test Album",
                genre: "Metal",
                year: 2020
            ),
            AppliedChangeExpectation(
                type: .yearUpdate,
                name: "Test Song",
                artist: "Test Artist",
                album: "Test Album",
                genre: "Rock",
                year: 2024
            ),
            AppliedChangeExpectation(
                type: .yearRevert,
                name: "Test Song",
                artist: "Test Artist",
                album: "Test Album",
                genre: "Rock",
                year: 1999
            ),
            AppliedChangeExpectation(
                type: .trackCleaning,
                name: "Clean Song",
                artist: "Test Artist",
                album: "Test Album",
                genre: "Rock",
                year: 2020
            ),
            AppliedChangeExpectation(
                type: .albumCleaning,
                name: "Test Song",
                artist: "Test Artist",
                album: "Clean Album",
                genre: "Rock",
                year: 2020
            ),
            AppliedChangeExpectation(
                type: .artistRename,
                name: "Test Song",
                artist: "Canonical Artist",
                album: "Test Album",
                genre: "Rock",
                year: 2020
            ),
        ]
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

    @Test("Persisted applied changes update only their target metadata")
    func appliesMetadataChanges() async throws {
        for expectation in appliedChangeExpectations {
            let store = try makeStore()
            try await store.initialize()
            try await store.saveTracks([sampleTrack()])

            try await store.persistAppliedChange(appliedChange(type: expectation.type))

            let stored = try #require(try await store.getTrack(byID: "T001"))
            #expect(stored.name == expectation.name)
            #expect(stored.artist == expectation.artist)
            #expect(stored.album == expectation.album)
            #expect(stored.genre == expectation.genre)
            #expect(stored.year == expectation.year)
        }
    }

    @Test("Genre and year writes complete processing state")
    func completesProcessingState() async throws {
        let store = try makeStore()
        try await store.initialize()
        try await store.saveTracks([sampleTrack()])

        try await store.persistAppliedChange(appliedChange(type: .genreUpdate))
        try await store.persistAppliedChange(appliedChange(type: .yearUpdate))

        #expect(try await store.getUnprocessedTracks().isEmpty)
    }

    @Test("Applied change persistence fails when the track is missing")
    func rejectsMissingTrack() async throws {
        let store = try makeStore()
        try await store.initialize()

        await #expect(throws: TrackStoreError.self) {
            try await store.persistAppliedChange(appliedChange(trackID: "MISSING", type: .genreUpdate))
        }
    }

    @Test("Applied change persistence fails when the new value is missing")
    func rejectsMissingValue() async throws {
        let store = try makeStore()
        try await store.initialize()
        try await store.saveTracks([sampleTrack()])
        let change = ChangeLogEntry(
            changeType: .genreUpdate,
            trackID: "T001",
            artist: "Test Artist"
        )

        await #expect(throws: TrackChangeError.self) {
            try await store.persistAppliedChange(change)
        }
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

        try await store.persistAppliedChange(appliedChange(trackID: "P1", type: .genreUpdate))
        try await store.persistAppliedChange(appliedChange(trackID: "P1", type: .yearUpdate))

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
}
