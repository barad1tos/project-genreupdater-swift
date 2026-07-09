import Foundation
import SwiftData
import Testing
@testable import Core
@testable import Services

// MARK: - Tests

@Suite("ChangeLogDataStore — CRUD operations")
struct ChangeLogDataTests {
    private func makeStore() throws -> ChangeLogDataStore {
        let container = try ModelContainerFactory.createInMemory()
        return ChangeLogDataStore(modelContainer: container)
    }

    private func makeEntry(
        changeType: ChangeType = .genreUpdate,
        trackID: String = "T1",
        oldGenre: String? = "Rock",
        newGenre: String? = "Pop"
    ) -> ChangeLogEntry {
        var entry = ChangeLogEntry(
            changeType: changeType,
            trackID: trackID,
            artist: "Artist",
            trackName: "Track",
            albumName: "Album"
        )
        entry.oldGenre = oldGenre
        entry.newGenre = newGenre
        return entry
    }

    @Test("Save and load single entry")
    func saveAndLoadSingle() async throws {
        let store = try makeStore()
        let entry = makeEntry()

        try await store.saveEntry(entry)
        let loaded = try await store.loadAll()

        #expect(loaded.count == 1)
        #expect(loaded[0].id == entry.id)
        #expect(loaded[0].trackID == "T1")
        #expect(loaded[0].changeType == .genreUpdate)
        #expect(loaded[0].oldGenre == "Rock")
        #expect(loaded[0].newGenre == "Pop")
    }

    @Test("Save multiple entries via batch")
    func saveBatch() async throws {
        let store = try makeStore()
        let entries = [
            makeEntry(trackID: "T1"),
            makeEntry(changeType: .yearUpdate, trackID: "T2"),
        ]

        try await store.saveEntries(entries)
        let loaded = try await store.loadAll()

        #expect(loaded.count == 2)
    }

    @Test("Delete single entry by ID")
    func deleteSingle() async throws {
        let store = try makeStore()
        let entry1 = makeEntry(trackID: "T1")
        let entry2 = makeEntry(trackID: "T2")

        try await store.saveEntries([entry1, entry2])
        try await store.delete(entryID: entry1.id)

        let loaded = try await store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded[0].id == entry2.id)
    }

    @Test("Delete all entries")
    func deleteAll() async throws {
        let store = try makeStore()
        try await store.saveEntries([
            makeEntry(trackID: "T1"),
            makeEntry(trackID: "T2"),
            makeEntry(trackID: "T3"),
        ])

        try await store.deleteAll()
        let loaded = try await store.loadAll()
        #expect(loaded.isEmpty)
    }

    @Test("Round-trip preserves all fields")
    func roundTripPreservesFields() async throws {
        let store = try makeStore()
        var entry = ChangeLogEntry(
            changeType: .yearUpdate,
            trackID: "T42",
            artist: "Iron Maiden",
            trackName: "Hallowed Be Thy Name",
            albumName: "The Number of the Beast"
        )
        entry.oldYear = 1982
        entry.newYear = 1983
        entry.oldArtist = "Old Maiden"
        entry.newArtist = "Iron Maiden"

        try await store.saveEntry(entry)
        let loaded = try await store.loadAll()

        #expect(loaded.count == 1)
        let result = loaded[0]
        #expect(result.id == entry.id)
        #expect(result.changeType == .yearUpdate)
        #expect(result.trackID == "T42")
        #expect(result.artist == "Iron Maiden")
        #expect(result.trackName == "Hallowed Be Thy Name")
        #expect(result.albumName == "The Number of the Beast")
        #expect(result.oldYear == 1982)
        #expect(result.newYear == 1983)
        #expect(result.oldArtist == "Old Maiden")
        #expect(result.newArtist == "Iron Maiden")
    }

    @Test("Load returns entries sorted by timestamp descending")
    func loadSortedByTimestamp() async throws {
        let store = try makeStore()
        let entry1 = makeEntry(trackID: "T1")
        // Small delay to ensure different timestamps
        try await Task.sleep(for: .milliseconds(10))
        let entry2 = makeEntry(trackID: "T2")

        try await store.saveEntries([entry1, entry2])
        let loaded = try await store.loadAll()

        #expect(loaded.count == 2)
        #expect(loaded[0].trackID == "T2")
        #expect(loaded[1].trackID == "T1")
    }

    @Test("Delete non-existent entry is a no-op")
    func deleteNonExistent() async throws {
        let store = try makeStore()
        try await store.saveEntry(makeEntry())

        try await store.delete(entryID: UUID())

        let loaded = try await store.loadAll()
        #expect(loaded.count == 1)
    }
}
