import Core
import Foundation
import SwiftData
import Testing
@testable import Services

@Suite("Metrics snapshot store")
struct MetricsSnapshotStoreTests {
    private func makeStore() throws -> MetricsSnapshotStore {
        try MetricsSnapshotStore(modelContainer: ModelContainerFactory.createInMemory())
    }

    private func track(id: String, genre: String?, status: String?, dateAdded: Date? = nil) -> Core.Track {
        Core.Track(
            id: id,
            name: id,
            artist: "Artist",
            album: "Album",
            genre: genre,
            year: genre == nil ? nil : 2001,
            dateAdded: dateAdded,
            trackStatus: status
        )
    }

    @Test("mixed editability evidence persists an unknown protected count")
    func mixedEvidencePersistsNil() async throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let values = await store.upsert(from: [
            track(id: "known", genre: "Rock", status: "prerelease", dateAdded: now.addingTimeInterval(-3 * 24 * 3600)),
            track(id: "no-evidence", genre: nil, status: nil, dateAdded: now.addingTimeInterval(-30 * 24 * 3600)),
        ], timestamp: now)

        // nil, never 0: the read side renders nil as "unknown".
        #expect(values?.protectedFileCount == nil)
        #expect(values?.totalTracks == 2)
        #expect(values?.tracksNeedingGenre == 1)
        #expect(values?.recentlyAdded == 1)
    }

    @Test("an all-known library persists the real protected count")
    func knownEvidencePersistsCount() async throws {
        let store = try makeStore()

        let values = await store.upsert(from: [
            track(id: "protected", genre: "Rock", status: "prerelease"),
            track(id: "editable", genre: "Rock", status: "purchased"),
        ])

        #expect(values?.protectedFileCount == 1)
    }

    @Test("an empty library persists nothing")
    func emptyLibraryPersistsNothing() async throws {
        let store = try makeStore()

        #expect(await store.upsert(from: []) == nil)
        #expect(await store.loadLatest() == nil)
    }

    @Test("a second upsert rotates the trend baseline")
    func secondUpsertRotatesBaseline() async throws {
        let store = try makeStore()
        let first = Date(timeIntervalSince1970: 1_800_000_000)

        await store.upsert(from: [
            track(id: "a", genre: nil, status: "purchased"),
            track(id: "b", genre: nil, status: "purchased"),
        ], timestamp: first)
        let second = await store.upsert(from: [
            track(id: "a", genre: "Rock", status: "purchased"),
            track(id: "b", genre: nil, status: "purchased"),
        ], timestamp: first.addingTimeInterval(3600))

        #expect(second?.tracksNeedingGenre == 1)
        #expect(second?.previousTracksNeedingGenre == 2)
        #expect(second?.previousTotalTracks == 2)
    }

    @Test("the recently-added window includes exactly seven days")
    func recentlyAddedWindowBoundary() async throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = Calendar.current
        let exactlySevenDays = try #require(calendar.date(byAdding: .day, value: -7, to: now))

        let values = await store.upsert(from: [
            track(id: "on-boundary", genre: "Rock", status: "purchased", dateAdded: exactlySevenDays),
            track(
                id: "past-boundary",
                genre: "Rock",
                status: "purchased",
                dateAdded: exactlySevenDays.addingTimeInterval(-1)
            ),
        ], timestamp: now)

        // dateAdded >= cutoff: the boundary itself counts, one second
        // earlier does not.
        #expect(values?.recentlyAdded == 1)
    }

    @Test("loadLatest returns the persisted values")
    func loadLatestReturnsPersisted() async throws {
        let store = try makeStore()

        let upserted = await store.upsert(from: [track(id: "a", genre: "Rock", status: "purchased")])
        let loaded = await store.loadLatest()

        #expect(loaded == upserted)
    }
}
