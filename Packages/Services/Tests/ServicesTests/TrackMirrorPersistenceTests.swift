import Foundation
import SwiftData
import Testing
@testable import Core
@testable import Services

@Suite("Track mirror persistence")
struct TrackMirrorPersistenceTests {
    private func track(id: String, name: String? = nil) -> Track {
        Track(
            id: id,
            name: name ?? id,
            artist: "Artist",
            album: "Album",
            appleScriptID: id
        )
    }

    private func databaseID(_ value: String) throws -> MusicDatabaseTrackID {
        try #require(MusicDatabaseTrackID(rawValue: value))
    }

    private func makeContainer(at url: URL) throws -> ModelContainer {
        let schema = ModelContainerFactory.makeSchema()
        let configuration = ModelConfiguration(
            "TrackMirrorRelaunch",
            schema: schema,
            url: url,
            cloudKitDatabase: .none
        )
        return try ModelContainerFactory.create(schema: schema, configuration: configuration)
    }

    @Test("Verified empty full-library coverage survives relaunch")
    func emptyCoveragePersists() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackMirrorSeed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tracks.store")

        do {
            let store = try TrackDataStore(modelContainer: makeContainer(at: url))
            try await store.initialize()
            try await store.applyMirror(TrackMirrorUpdate(
                baseRevision: .initial,
                coverageChange: .replace(.fullLibrary),
                repairs: [],
                upserts: [],
                deletions: []
            ))
        }

        let relaunched = try TrackDataStore(modelContainer: makeContainer(at: url))
        try await relaunched.initialize()
        let snapshot = try await relaunched.loadMirrorSnapshot()
        #expect(snapshot.tracks.isEmpty)
        #expect(snapshot.coverage == .verified(.fullLibrary))
    }

    @Test("Mirror revision advances across commits and survives relaunch")
    func revisionPersists() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackMirrorRevision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tracks.store")

        do {
            let store = try TrackDataStore(modelContainer: makeContainer(at: url))
            try await store.initialize()
            let first = try await store.applyMirror(TrackMirrorUpdate(
                baseRevision: .initial,
                coverageChange: .replace(.fullLibrary),
                repairs: [],
                upserts: [track(id: "keep"), track(id: "delete")],
                deletions: []
            ))
            let second = try await store.applyMirror(TrackMirrorUpdate(
                baseRevision: first,
                coverageChange: .preserve,
                repairs: [],
                upserts: [],
                deletions: []
            ))
            #expect(first == MirrorRevision(value: 1))
            #expect(second == MirrorRevision(value: 2))
        }

        let expectedSnapshot: TrackMirrorSnapshot
        do {
            let relaunched = try TrackDataStore(modelContainer: makeContainer(at: url))
            try await relaunched.initialize()
            expectedSnapshot = try await relaunched.loadMirrorSnapshot()
            #expect(expectedSnapshot.revision == MirrorRevision(value: 2))
            #expect(expectedSnapshot.coverage == .verified(.fullLibrary))

            await #expect(throws: MirrorRevisionConflict(
                expected: MirrorRevision(value: 1),
                actual: MirrorRevision(value: 2)
            )) {
                try await relaunched.applyMirror(TrackMirrorUpdate(
                    baseRevision: MirrorRevision(value: 1),
                    coverageChange: .invalidate,
                    repairs: [],
                    upserts: [track(id: "keep", name: "Changed"), track(id: "insert")],
                    deletions: [databaseID("delete")]
                ))
            }
            #expect(try await relaunched.loadMirrorSnapshot() == expectedSnapshot)
        }

        let reopened = try TrackDataStore(modelContainer: makeContainer(at: url))
        try await reopened.initialize()
        #expect(try await reopened.loadMirrorSnapshot() == expectedSnapshot)
    }

    @Test("Maximum persisted revision rejects a commit without mutating the mirror")
    func maximumRevisionRollsBack() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackMirrorExhaustion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tracks.store")
        let expectedSnapshot: TrackMirrorSnapshot
        do {
            let container = try makeContainer(at: url)
            let context = ModelContext(container)
            context.insert(PersistedMirrorState(revisionValue: .max))
            try context.insert(PersistedTrack(mirror: track(id: "keep"), databaseID: databaseID("keep")))
            try context.insert(PersistedTrack(mirror: track(id: "delete"), databaseID: databaseID("delete")))
            try context.save()
            let store = TrackDataStore(modelContainer: container)
            expectedSnapshot = try await store.loadMirrorSnapshot()

            do {
                _ = try await store.applyMirror(TrackMirrorUpdate(
                    baseRevision: expectedSnapshot.revision,
                    coverageChange: .replace(.fullLibrary),
                    repairs: [],
                    upserts: [track(id: "keep", name: "Changed"), track(id: "insert")],
                    deletions: [databaseID("delete")]
                ))
                Issue.record("A mirror commit must fail when its revision is exhausted")
            } catch {
                #expect(error.localizedDescription == "Mirror revision exhausted at \(UInt64.max).")
            }
            #expect(try await store.loadMirrorSnapshot() == expectedSnapshot)
        }

        let reopened = try TrackDataStore(modelContainer: makeContainer(at: url))
        try await reopened.initialize()
        #expect(try await reopened.loadMirrorSnapshot() == expectedSnapshot)
    }
}
