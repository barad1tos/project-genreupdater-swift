import Foundation
import SwiftData
import Testing
@testable import Services

@Suite("Physical catalog persistence")
struct CatalogDataStoreTests {
    @Test("The catalog store owns a SwiftData model executor")
    func ownsModelExecutor() throws {
        let store = try CatalogDataStore(modelContainer: ModelContainerFactory.createInMemory())

        requireModelActor(store)
    }

    @Test("A complete catalog snapshot replaces the previous snapshot atomically")
    func replacesCompleteSnapshot() async throws {
        let store = try CatalogDataStore(modelContainer: ModelContainerFactory.createInMemory())
        let initial = snapshot(
            tracks: [track(id: "old-1"), track(id: "old-2")],
            capturedAt: Date(timeIntervalSince1970: 100)
        )
        let replacement = snapshot(
            tracks: [
                track(
                    id: "new-2",
                    title: "Bachelorette",
                    artist: "Björk",
                    album: "Homogenic",
                    albumArtist: "Björk",
                    genres: ["Electronic", "Alternative"],
                    releaseYear: 1997,
                    dateAdded: Date(timeIntervalSince1970: 200)
                ),
                track(id: "new-1"),
            ],
            capturedAt: Date(timeIntervalSince1970: 300)
        )

        try await store.replaceSnapshot(initial)
        try await store.replaceSnapshot(replacement)

        #expect(try await store.loadSnapshot() == replacement)
    }

    @Test("Duplicate catalog IDs roll back without damaging the previous snapshot")
    func rejectsDuplicatesWithoutLosingPreviousSnapshot() async throws {
        let store = try CatalogDataStore(modelContainer: ModelContainerFactory.createInMemory())
        let previous = snapshot(
            tracks: [track(id: "preserved")],
            capturedAt: Date(timeIntervalSince1970: 400)
        )
        try await store.replaceSnapshot(previous)
        let invalid = snapshot(
            tracks: [
                track(id: "duplicate", title: "First"),
                track(id: "duplicate", title: "Second"),
            ],
            capturedAt: Date(timeIntervalSince1970: 500)
        )

        await #expect(throws: CatalogStoreError.duplicateIDs(["duplicate"])) {
            try await store.replaceSnapshot(invalid)
        }

        #expect(try await store.loadSnapshot() == previous)
    }

    @Test("An explicitly empty catalog remains distinguishable from no captured catalog")
    func persistsEmptySnapshot() async throws {
        let store = try CatalogDataStore(modelContainer: ModelContainerFactory.createInMemory())
        #expect(try await store.loadSnapshot() == nil)
        let empty = snapshot(tracks: [], capturedAt: Date(timeIntervalSince1970: 600))

        try await store.replaceSnapshot(empty)

        #expect(try await store.loadSnapshot() == empty)
    }

    @Test("The physical catalog survives a persistent store relaunch")
    func survivesRelaunch() async throws {
        let fixture = try PersistentCatalogFixture()
        defer { fixture.remove() }
        let expected = snapshot(
            tracks: [track(id: "catalog-1"), track(id: "catalog-2")],
            capturedAt: Date(timeIntervalSince1970: 700)
        )

        do {
            try await CatalogDataStore(modelContainer: fixture.openContainer()).replaceSnapshot(expected)
        }

        let relaunched = try CatalogDataStore(modelContainer: fixture.openContainer())
        #expect(try await relaunched.loadSnapshot() == expected)
    }

    private func snapshot(tracks: [CatalogTrack], capturedAt: Date) -> CatalogSnapshot {
        CatalogSnapshot(tracks: tracks, capturedAt: capturedAt)
    }

    private func track(
        id: String,
        title: String = "Track",
        artist: String = "Artist",
        album: String = "Album",
        albumArtist: String? = nil,
        genres: [String] = [],
        releaseYear: Int? = nil,
        dateAdded: Date? = nil
    ) -> CatalogTrack {
        guard let catalogID = CatalogTrackID(displayValue: id) else {
            fatalError("Catalog fixture IDs must be non-empty")
        }
        return CatalogTrack(
            id: catalogID,
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            genres: genres,
            dates: CatalogDates(releaseYear: releaseYear, dateAdded: dateAdded)
        )
    }

    private func requireModelActor(_: some ModelActor) {}
}

private struct PersistentCatalogFixture {
    let directory: URL
    let storeURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatalogDataStore-\(UUID().uuidString)", isDirectory: true)
        storeURL = directory.appendingPathComponent("catalog.store")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func openContainer() throws -> ModelContainer {
        let schema = ModelContainerFactory.makeSchema()
        let configuration = ModelConfiguration(
            "CatalogDataStore",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        return try ModelContainerFactory.create(schema: schema, configuration: configuration)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
