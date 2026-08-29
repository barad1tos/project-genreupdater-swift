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
                inventoryChange: replacementInventory(for: [MusicDatabaseTrackID]()),
                repairs: [],
                upserts: [],
                certificates: .invalidate(.membershipChanged)
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
                inventoryChange: replacementInventory(for: initialTracks),
                repairs: [],
                upserts: initialTracks,
                certificates: .invalidate(.membershipChanged)
            ))
            let second = try await store.commitMirror(MirrorCommit(
                baseRevision: first.revision,
                inventoryChange: .preserve,
                repairs: [],
                upserts: [],
                certificates: .preserve
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
                    inventoryChange: replacementInventory(for: [
                        track(id: "keep", name: "Changed"),
                        track(id: "insert"),
                    ]),
                    repairs: [],
                    upserts: [track(id: "keep", name: "Changed"), track(id: "insert")],
                    certificates: .invalidate(.incompleteObservation)
                ))
            }
            #expect(try await relaunched.loadMirrorSnapshot() == expectedSnapshot)
        }

        let reopened = try TrackDataStore(modelContainer: makeContainer(at: url))
        try await reopened.initialize()
        #expect(try await reopened.loadMirrorSnapshot() == expectedSnapshot)
    }

    @Test("A mirror commit returns the exact snapshot accepted by its transaction")
    func commitReturnsAcceptedSnapshot() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = TrackDataStore(modelContainer: container)
        try await store.initialize()
        let inserted = track(id: "inserted")

        let result = try await store.commitMirror(MirrorCommit(
            baseRevision: .initial,
            inventoryChange: replacementInventory(for: [inserted]),
            repairs: [],
            upserts: [inserted],
            certificates: .invalidate(.membershipChanged)
        ))

        #expect(result.snapshot?.revision == result.revision)
        #expect(result.snapshot?.presentTracks == [inserted])
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
                    inventoryChange: replacementInventory(for: [
                        track(id: "keep", name: "Changed"),
                        track(id: "insert"),
                    ]),
                    repairs: [],
                    upserts: [track(id: "keep", name: "Changed"), track(id: "insert")],
                    certificates: .invalidate(.membershipChanged)
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

    @Test("Mismatched synchronization evidence rolls back the atomic mirror commit")
    func invalidSyncEvidenceRollsBack() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = TrackDataStore(modelContainer: container)
        try await store.initialize()
        let memberID = try databaseID("A")
        let inventory = try replacementInventory(for: [memberID])
        let certificate = try scopeCertificate(
            revision: MirrorRevision(value: 1),
            inventoryChange: inventory,
            trackIDs: [memberID]
        )
        let observation = ObservationID()
        let record = MirrorSyncRecord(
            observation: observation,
            revisions: MirrorSyncRevisions(base: .initial, committed: MirrorRevision(value: 1)),
            evidence: MirrorSyncEvidence(
                membership: certificate.membership,
                scopeID: UUID(),
                certificateID: UUID()
            ),
            mode: .force,
            window: MirrorSyncWindow(
                startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                completedAt: Date(timeIntervalSince1970: 1_800_000_001)
            ),
            delta: MirrorSyncCounts(new: 1, modified: 0, identityChanged: 0, refreshed: 0, removed: 0),
            coverage: MirrorSyncCoverage(
                identityRequestedCount: 1,
                identityObservedCount: 1,
                metadataRequestedCount: 1,
                metadataObservedCount: 1,
                isMembershipComplete: true,
                isIdentityComplete: true,
                isMetadataComplete: true
            )
        )

        await #expect(throws: TrackStoreError.invalidSyncRecord) {
            try await store.commitMirror(MirrorCommit(
                baseRevision: .initial,
                observation: observation,
                inventoryChange: inventory,
                repairs: [],
                upserts: [track(id: "A")],
                certificates: .replace(certificate),
                syncRecord: record
            ))
        }

        let snapshot = try await store.loadMirrorSnapshot()
        #expect(snapshot.revision == .initial)
        #expect(snapshot.presentIDs.isEmpty)
        #expect(snapshot.presentTracks.isEmpty)
        #expect(snapshot.certificates.isEmpty)
        #expect(try ModelContext(container).fetch(FetchDescriptor<PersistedSyncRecord>()).isEmpty)
    }
}
