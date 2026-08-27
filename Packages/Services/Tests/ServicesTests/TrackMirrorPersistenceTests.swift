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

    @Test("An empty full-library membership survives relaunch without a certificate")
    func emptyMembershipPersists() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackMirrorSeed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tracks.store")

        do {
            let store = try TrackDataStore(modelContainer: makeContainer(at: url))
            try await store.initialize()
            try await store.commitMirror(MirrorCommit(
                baseRevision: .initial,
                certificates: .invalidate(.membershipChanged),
                membershipChange: replacementMembership(for: [MusicDatabaseTrackID]()),
                repairs: [],
                upserts: []
            ))
        }

        let relaunched = try TrackDataStore(modelContainer: makeContainer(at: url))
        try await relaunched.initialize()
        let snapshot = try await relaunched.loadMirrorSnapshot()
        #expect(snapshot.presentTracks.isEmpty)
        #expect(snapshot.certificates.isEmpty)
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
            let initialTracks = [track(id: "keep"), track(id: "delete")]
            let first = try await store.commitMirror(MirrorCommit(
                baseRevision: .initial,
                certificates: .invalidate(.metadataChanged),
                membershipChange: replacementMembership(for: initialTracks),
                repairs: [],
                upserts: initialTracks
            ))
            let second = try await store.commitMirror(MirrorCommit(
                baseRevision: first.revision,
                certificates: .preserve,
                membershipChange: .preserve,
                repairs: [],
                upserts: []
            ))
            #expect(first.revision == MirrorRevision(value: 1))
            #expect(second.revision == MirrorRevision(value: 2))
        }

        let expectedSnapshot: TrackMirrorSnapshot
        do {
            let relaunched = try TrackDataStore(modelContainer: makeContainer(at: url))
            try await relaunched.initialize()
            expectedSnapshot = try await relaunched.loadMirrorSnapshot()
            #expect(expectedSnapshot.revision == MirrorRevision(value: 2))
            #expect(expectedSnapshot.certificates.isEmpty)

            await #expect(throws: MirrorRevisionConflict(
                expected: MirrorRevision(value: 1),
                actual: MirrorRevision(value: 2)
            )) {
                try await relaunched.commitMirror(MirrorCommit(
                    baseRevision: MirrorRevision(value: 1),
                    certificates: .invalidate(.incompleteObservation),
                    membershipChange: replacementMembership(for: [
                        track(id: "keep", name: "Changed"),
                        track(id: "insert"),
                    ]),
                    repairs: [],
                    upserts: [track(id: "keep", name: "Changed"), track(id: "insert")]
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
            context.insert(PersistedLibraryMember(
                databaseID: "keep",
                isPresent: true,
                firstSeenRevisionValue: .max
            ))
            context.insert(PersistedLibraryMember(
                databaseID: "delete",
                isPresent: true,
                firstSeenRevisionValue: .max
            ))
            try context.save()
            let store = TrackDataStore(modelContainer: container)
            expectedSnapshot = try await store.loadMirrorSnapshot()

            do {
                _ = try await store.commitMirror(MirrorCommit(
                    baseRevision: expectedSnapshot.revision,
                    certificates: .invalidate(.metadataChanged),
                    membershipChange: replacementMembership(for: [
                        track(id: "keep", name: "Changed"),
                        track(id: "insert"),
                    ]),
                    repairs: [],
                    upserts: [track(id: "keep", name: "Changed"), track(id: "insert")]
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
