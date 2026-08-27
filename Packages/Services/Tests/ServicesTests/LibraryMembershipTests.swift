import Foundation
import SwiftData
import Testing
@testable import Core
@testable import Services

@Suite("Library membership")
struct LibraryMembershipTests {
    @Test("Fingerprint is independent of census order")
    func fingerprintIgnoresOrder() throws {
        let first = try MembershipFingerprint.make(ids: [databaseID("A"), databaseID("B")])
        let second = try MembershipFingerprint.make(ids: [databaseID("B"), databaseID("A")])

        #expect(first == second)
        #expect(first.fingerprint == "80dbee5c63d4a60dd69c57da86e9168b91a6edbef51e793adf1923823caa2fec")
    }

    @Test("Fingerprint rejects duplicate database IDs")
    func fingerprintRejectsDuplicates() throws {
        let duplicate = try databaseID("A")

        #expect(throws: MembershipFingerprintError.duplicateIDs([duplicate])) {
            try MembershipFingerprint.make(ids: [duplicate, duplicate])
        }
    }

    @Test("Empty census has a deterministic stamp")
    func emptyCensusHasStamp() throws {
        let stamp = try MembershipFingerprint.make(ids: [])

        #expect(stamp.fingerprint == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("Initial census inserts present members")
    func initialCensusInsertsMembers() async throws {
        let fixture = try makeFixture()
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let ids = try [databaseID("A"), databaseID("B")]

        let revision = try await replaceMembership(
            in: fixture.store,
            ids: ids,
            tracks: ids.map(track),
            observedAt: observedAt
        )

        #expect(revision == MirrorRevision(value: 1))
        #expect(try presentIDs(in: fixture.container) == ids)
        let members = try loadMembers(from: fixture.container)
        #expect(members.count == 2)
        #expect(members.filter(\.isPresent).count == members.count)
        #expect(members.allSatisfy { $0.firstSeenRevisionValue == 1 })
        #expect(members.allSatisfy { $0.removalRevisionValue == nil && $0.removedAt == nil })
    }

    @Test("Unchanged census preserves membership transition fields")
    func preservesMembers() async throws {
        let fixture = try makeFixture()
        let ids = try [databaseID("A"), databaseID("B")]
        _ = try await replaceMembership(in: fixture.store, ids: ids, tracks: ids.map(track))
        let before = try loadMembers(from: fixture.container).map(MemberRecord.init)

        _ = try await replaceMembership(in: fixture.store, ids: ids)

        let after = try loadMembers(from: fixture.container).map(MemberRecord.init)
        #expect(after.map(\.databaseID) == before.map(\.databaseID))
        #expect(after.map(\.isPresent) == before.map(\.isPresent))
        #expect(after.map(\.firstSeenRevisionValue) == before.map(\.firstSeenRevisionValue))
        #expect(after.map(\.lastSeenFingerprint) == before.map(\.lastSeenFingerprint))
        #expect(after.map(\.removalRevisionValue) == before.map(\.removalRevisionValue))
        #expect(after.map(\.removedAt) == before.map(\.removedAt))
    }

    @Test("Changed census advances retained and added member stamps")
    func changedCensusUpdatesStamps() async throws {
        let fixture = try makeFixture()
        let firstIDs = try [databaseID("A"), databaseID("B")]
        let secondIDs = try [databaseID("A"), databaseID("C")]
        let firstStamp = try MembershipFingerprint.make(ids: firstIDs)
        let secondStamp = try MembershipFingerprint.make(ids: secondIDs)
        _ = try await replaceMembership(in: fixture.store, ids: firstIDs, tracks: firstIDs.map(track))

        _ = try await replaceMembership(in: fixture.store, ids: secondIDs, tracks: [track(id: secondIDs[1])])

        let members = try Dictionary(uniqueKeysWithValues: loadMembers(from: fixture.container).map {
            ($0.databaseID, $0)
        })
        #expect(members["A"]?.lastSeenFingerprint == secondStamp.fingerprint)
        #expect(members["B"]?.lastSeenFingerprint == firstStamp.fingerprint)
        #expect(members["C"]?.lastSeenFingerprint == secondStamp.fingerprint)
    }

    @Test("Removal tombstones membership and retains metadata history")
    func removalRetainsHistory() async throws {
        let fixture = try makeFixture()
        let ids = try [databaseID("A"), databaseID("B")]
        _ = try await replaceMembership(in: fixture.store, ids: ids, tracks: ids.map(track))
        let history = ChangeLogDataStore(modelContainer: fixture.container)
        try await history.saveEntry(change(trackID: "B"))
        let removedAt = Date(timeIntervalSince1970: 1_700_000_100)

        let revision = try await replaceMembership(
            in: fixture.store,
            ids: [ids[0]],
            observedAt: removedAt
        )

        #expect(revision == MirrorRevision(value: 2))
        #expect(try await fixture.store.loadAllTracks().map(\.id) == ["A"])
        #expect(try await fixture.store.getTrack(byID: "B") == nil)
        #expect(try await fixture.store.getHistoricalTrack(byID: "B")?.name == "Track B")
        #expect(try await history.loadAll().map(\.trackID) == ["B"])
        let removed = try #require(loadMembers(from: fixture.container).first { $0.databaseID == "B" })
        #expect(!removed.isPresent)
        #expect(removed.firstSeenRevisionValue == 1)
        #expect(removed.removalRevisionValue == 2)
        #expect(removed.removedAt == removedAt)
    }

    @Test("A later census resurrects a tombstoned member")
    func censusResurrectsMember() async throws {
        let fixture = try makeFixture()
        let ids = try [databaseID("A"), databaseID("B")]
        _ = try await replaceMembership(in: fixture.store, ids: ids, tracks: ids.map(track))
        _ = try await replaceMembership(in: fixture.store, ids: [ids[0]])

        let revision = try await replaceMembership(in: fixture.store, ids: ids)

        #expect(revision == MirrorRevision(value: 3))
        #expect(try await fixture.store.loadAllTracks().map(\.id).sorted() == ["A", "B"])
        let resurrected = try #require(loadMembers(from: fixture.container).first { $0.databaseID == "B" })
        #expect(resurrected.isPresent)
        #expect(resurrected.firstSeenRevisionValue == 1)
        #expect(resurrected.removalRevisionValue == nil)
        #expect(resurrected.removedAt == nil)
    }

    @Test("Empty authoritative census tombstones every member")
    func emptyCensusTombstonesMembers() async throws {
        let fixture = try makeFixture()
        let ids = try [databaseID("A"), databaseID("B")]
        _ = try await replaceMembership(in: fixture.store, ids: ids, tracks: ids.map(track))

        _ = try await replaceMembership(in: fixture.store, ids: [])

        #expect(try await fixture.store.loadAllTracks().isEmpty)
        #expect(try presentIDs(in: fixture.container).isEmpty)
        #expect(try loadMembers(from: fixture.container).allSatisfy { !$0.isPresent })
    }

    @Test("Corrupt persisted membership fails instead of shrinking the mirror")
    func corruptMembershipFailsRead() async throws {
        let fixture = try makeFixture()
        let context = ModelContext(fixture.container)
        context.insert(PersistedLibraryMember(
            databaseID: " ",
            isPresent: true,
            firstSeenRevisionValue: 1
        ))
        try context.save()

        await #expect(throws: TrackStoreError.invalidMembershipIDs(ids: [" "])) {
            try await fixture.store.loadMirrorSnapshot()
        }
    }

    @Test("Unchanged 30K census preserves every processing row")
    func largeCensusPreservesRows() async throws {
        let trackCount = 30000
        let fixture = try makeFixture()
        let ids = try (0 ..< trackCount).map { index in
            try databaseID(String(format: "TRACK-%05d", index))
        }
        let stamp = try MembershipFingerprint.make(ids: ids)
        let context = ModelContext(fixture.container)
        context.insert(PersistedMirrorState(revisionValue: 1))
        for (index, id) in ids.enumerated() {
            let persisted = PersistedTrack(mirror: track(id: id), databaseID: id)
            persisted.genreUpdated = index.isMultiple(of: 2)
            persisted.yearUpdated = index.isMultiple(of: 3)
            persisted.processedDate = Date(timeIntervalSince1970: TimeInterval(index))
            context.insert(persisted)
            context.insert(PersistedLibraryMember(
                databaseID: id.rawValue,
                isPresent: true,
                firstSeenRevisionValue: 1,
                lastSeenFingerprint: stamp.fingerprint
            ))
        }
        try context.save()
        let before = try loadProcessingRecords(from: fixture.container)

        _ = try await replaceMembership(in: fixture.store, ids: ids)

        let after = try loadProcessingRecords(from: fixture.container)
        #expect(after.map(\.trackID) == before.map(\.trackID))
        #expect(after.map(\.isGenreUpdated) == before.map(\.isGenreUpdated))
        #expect(after.map(\.isYearUpdated) == before.map(\.isYearUpdated))
        #expect(after.map(\.processedDate) == before.map(\.processedDate))
        #expect(try presentIDs(in: fixture.container).count == trackCount)
    }

    @Test("V2 migration preserves canonical rows as uncertified present members")
    func v2MigrationCreatesMembers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MembershipMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("tracks.store")
        let entryID = UUID()

        do {
            let container = try makeV2Container(at: storeURL)
            let context = ModelContext(container)
            let canonical = PersistedTrack(
                trackID: "canonical",
                appleScriptID: "canonical",
                name: "Canonical",
                artist: "Artist",
                album: "Album"
            )
            let legacy = PersistedTrack(
                trackID: "catalog",
                appleScriptID: "database",
                name: "Legacy",
                artist: "Artist",
                album: "Album"
            )
            let history = PersistedChangeLogEntry(
                entryID: entryID,
                timestamp: .now,
                changeTypeRaw: ChangeType.genreUpdate.rawValue,
                trackID: "canonical",
                artist: "Artist",
                trackName: "Canonical",
                albumName: "Album"
            )
            history.track = canonical
            context.insert(PersistedMirrorState(revisionValue: 7))
            context.insert(canonical)
            context.insert(legacy)
            context.insert(history)
            try context.save()
        }

        for _ in 0 ..< 2 {
            let container = try makeCurrentContainer(at: storeURL)
            let members = try loadMembers(from: container)
            let member = try #require(members.first)
            #expect(members.count == 1)
            #expect(member.databaseID == "canonical")
            #expect(member.isPresent)
            #expect(member.firstSeenRevisionValue == 7)
            #expect(member.lastSeenFingerprint == nil)
            let history = try ModelContext(container).fetch(FetchDescriptor<PersistedChangeLogEntry>())
            #expect(history.map(\.entryID) == [entryID])
        }
    }

    private struct Fixture {
        let store: TrackDataStore
        let container: ModelContainer
    }

    private struct MemberRecord {
        let databaseID: String
        let isPresent: Bool
        let firstSeenRevisionValue: UInt64
        let lastSeenFingerprint: String?
        let removalRevisionValue: UInt64?
        let removedAt: Date?

        init(_ member: PersistedLibraryMember) {
            databaseID = member.databaseID
            isPresent = member.isPresent
            firstSeenRevisionValue = member.firstSeenRevisionValue
            lastSeenFingerprint = member.lastSeenFingerprint
            removalRevisionValue = member.removalRevisionValue
            removedAt = member.removedAt
        }
    }

    private struct ProcessingRecord {
        let trackID: String
        let isGenreUpdated: Bool
        let isYearUpdated: Bool
        let processedDate: Date?

        init(_ track: PersistedTrack) {
            trackID = track.trackID
            isGenreUpdated = track.genreUpdated
            isYearUpdated = track.yearUpdated
            processedDate = track.processedDate
        }
    }

    private func makeFixture() throws -> Fixture {
        let container = try ModelContainerFactory.createInMemory()
        return Fixture(store: TrackDataStore(modelContainer: container), container: container)
    }

    private func makeV2Container(at url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: StoreSchemaV2.self)
        let configuration = ModelConfiguration(
            "MembershipMigration",
            schema: schema,
            url: url,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func makeCurrentContainer(at url: URL) throws -> ModelContainer {
        let schema = ModelContainerFactory.makeSchema()
        let configuration = ModelConfiguration(
            "MembershipMigration",
            schema: schema,
            url: url,
            cloudKitDatabase: .none
        )
        return try ModelContainerFactory.create(schema: schema, configuration: configuration)
    }

    private func replaceMembership(
        in store: TrackDataStore,
        ids: [MusicDatabaseTrackID],
        tracks: [Track] = [],
        observedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) async throws -> MirrorRevision {
        let revision = try await store.loadMirrorSnapshot().revision
        let stamp = try MembershipFingerprint.make(ids: ids)
        return try await store.commitMirror(MirrorCommit(
            baseRevision: revision,
            certificates: .invalidate(tracks.isEmpty ? .membershipChanged : .metadataChanged),
            membershipChange: .replace(stamp: stamp, ids: ids, observedAt: observedAt),
            repairs: [],
            upserts: tracks
        )).revision
    }

    private func loadMembers(from container: ModelContainer) throws -> [PersistedLibraryMember] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<PersistedLibraryMember>(
            sortBy: [SortDescriptor(\.databaseID)]
        ))
    }

    private func loadProcessingRecords(from container: ModelContainer) throws -> [ProcessingRecord] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<PersistedTrack>(
            sortBy: [SortDescriptor(\.trackID)]
        )).map(ProcessingRecord.init)
    }

    private func track(id: MusicDatabaseTrackID) -> Track {
        Track(
            id: id.rawValue,
            name: "Track \(id.rawValue)",
            artist: "Artist",
            album: "Album",
            appleScriptID: id.rawValue
        )
    }

    private func change(trackID: String) -> ChangeLogEntry {
        ChangeLogEntry(
            changeType: .genreUpdate,
            trackID: trackID,
            artist: "Artist",
            trackName: "Track \(trackID)",
            albumName: "Album"
        )
    }

    private func databaseID(_ rawValue: String) throws -> MusicDatabaseTrackID {
        try #require(MusicDatabaseTrackID(rawValue: rawValue))
    }
}
