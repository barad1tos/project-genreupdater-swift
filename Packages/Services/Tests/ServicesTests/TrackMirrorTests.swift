import Foundation
import SwiftData
import Testing
@testable import Core
@testable import Services

@Suite("Atomic track mirror")
struct TrackMirrorTests {
    private func makeStore() throws -> TrackDataStore {
        try TrackDataStore.createInMemory()
    }

    private func makeContainer(at url: URL) throws -> ModelContainer {
        let schema = Schema([
            PersistedTrack.self,
            PersistedMirrorState.self,
            PersistedChangeLogEntry.self,
            PersistedLibraryMember.self,
        ])
        let configuration = ModelConfiguration(
            "TrackMirrorRelaunch",
            schema: schema,
            url: url,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func makeLegacyContainer(at url: URL) throws -> ModelContainer {
        let schema = Schema([PersistedTrack.self, PersistedChangeLogEntry.self])
        let configuration = ModelConfiguration(
            "TrackMirrorRelaunch",
            schema: schema,
            url: url,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func makeMemoryContainer() throws -> ModelContainer {
        let schema = Schema([
            PersistedTrack.self,
            PersistedMirrorState.self,
            PersistedChangeLogEntry.self,
            PersistedLibraryMember.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func makeNoncanonicalFixture(id: String) throws -> (store: TrackDataStore, container: ModelContainer) {
        let container = try makeMemoryContainer()
        let track = sampleTrack(id: id)
        let context = ModelContext(container)
        context.insert(PersistedTrack(
            trackID: id,
            name: track.name,
            artist: track.artist,
            album: track.album,
            genre: track.genre,
            year: track.year,
            dateAdded: track.dateAdded
        ))
        try context.save()
        return (TrackDataStore(modelContainer: container), container)
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

    private func mirrorTrack(id: String, name: String = "Test Song") -> Track {
        var track = sampleTrack(id: id, name: name)
        track.appleScriptID = id
        return track
    }

    private func databaseID(_ rawValue: String) throws -> MusicDatabaseTrackID {
        try #require(MusicDatabaseTrackID(rawValue: rawValue))
    }

    @Test("A fresh store exposes unknown mirror coverage")
    func freshCoverageIsUnknown() async throws {
        let store = try makeStore()
        try await store.initialize()

        let snapshot = try await store.loadMirrorSnapshot()

        #expect(snapshot.presentTracks.isEmpty)
        #expect(snapshot.coverage == .unknown)
    }

    @Test("Replacing coverage records authoritative empty full-library state")
    func emptyFullLibraryIsVerified() async throws {
        let store = try makeStore()
        try await store.initialize()

        try await store.applyMirror(TrackMirrorUpdate(
            baseRevision: .initial,
            coverageChange: .replace(.fullLibrary),
            membershipChange: replacementMembership(for: [MusicDatabaseTrackID]()),
            repairs: [],
            upserts: []
        ))
        let snapshot = try await store.loadMirrorSnapshot()

        #expect(snapshot.presentTracks.isEmpty)
        #expect(snapshot.coverage == .verified(.fullLibrary))
    }

    @Test("A rejected mirror update does not replace fresh coverage")
    func rejectionPreservesCoverage() async throws {
        let store = try makeStore()
        try await store.initialize()

        await #expect(throws: TrackStoreError.missingDatabaseID(trackID: "invalid")) {
            try await store.applyMirror(TrackMirrorUpdate(
                baseRevision: .initial,
                coverageChange: .replace(.fullLibrary),
                membershipChange: replacementMembership(for: [MusicDatabaseTrackID]()),
                repairs: [],
                upserts: [sampleTrack(id: "invalid")]
            ))
        }

        #expect(try await store.loadMirrorSnapshot().coverage == .unknown)
    }

    private func expectRepairedTrack(
        _ track: PersistedTrack,
        hasSameIdentity: Bool,
        processedAt: Date
    ) {
        #expect(hasSameIdentity)
        #expect(track.trackID == "database-id")
        #expect(track.appleScriptID == "database-id")
        #expect(track.name == "Canonical Name")
        #expect(track.artist == "Canonical Artist")
        #expect(track.album == "Canonical Album")
        #expect(track.genre == "Metal")
        #expect(track.year == 2001)
        #expect(track.albumArtist == "Canonical Album Artist")
        #expect(track.trackStatus == "matched")
        #expect(track.releaseYear == 2000)
        #expect(track.genreUpdated)
        #expect(track.yearUpdated)
        #expect(track.processedDate == processedAt)
        #expect(track.lastError == "preserved error")
        #expect(track.originalArtist == "Original Artist")
        #expect(track.originalAlbum == "Original Album")
        #expect(track.yearBeforeMGU == 1998)
        #expect(track.yearSetByMGU == 1999)
    }

    private func expectMergedTrack(_ track: PersistedTrack, processedAt: Date) {
        #expect(track.trackID == "AS1")
        #expect(track.name == "Live")
        #expect((track.artist, track.album) == ("Live", "Live"))
        #expect(track.genreUpdated)
        #expect(track.yearUpdated)
        #expect(track.processedDate == processedAt)
        #expect(track.lastError == "canonical error")
        #expect(track.originalArtist == "Stored Artist")
        #expect(track.originalAlbum == "Legacy Album")
        #expect(track.yearBeforeMGU == 1998)
        #expect(track.yearSetByMGU == 1999)
    }

    private func makeLegacyFixture(processedAt: Date) -> (
        track: PersistedTrack,
        linked: PersistedChangeLogEntry,
        unlinked: PersistedChangeLogEntry
    ) {
        let track = PersistedTrack(
            trackID: "catalog-id", name: "Legacy Name", artist: "Legacy Artist", album: "Legacy Album",
            genre: "Rock", year: 1999, genreUpdated: true, yearUpdated: true, processedDate: processedAt,
            lastError: "preserved error", originalArtist: "Original Artist", originalAlbum: "Original Album",
            yearBeforeMGU: 1998, yearSetByMGU: 1999
        )
        let linked = PersistedChangeLogEntry(
            entryID: UUID(), timestamp: .now, changeTypeRaw: ChangeType.genreUpdate.rawValue,
            trackID: "catalog-id", artist: "Legacy Artist", trackName: "Legacy Name", albumName: "Legacy Album"
        )
        linked.track = track
        let unlinked = PersistedChangeLogEntry(
            entryID: UUID(), timestamp: .now, changeTypeRaw: ChangeType.yearUpdate.rawValue,
            trackID: "catalog-id", artist: "Legacy Artist", trackName: "Legacy Name", albumName: "Legacy Album"
        )
        return (track, linked, unlinked)
    }

    private func appliedChange(trackID: String = "T001", type: ChangeType) -> ChangeLogEntry {
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

    @Test("Mirror apply commits upserts and tombstones while preserving app state")
    func applyMirrorPreservesState() async throws {
        let store = try makeStore()
        try await store.initialize()
        try await store.seedMirror([
            mirrorTrack(id: "T001"),
            mirrorTrack(id: "T002", name: "Removed Song"),
        ])
        try await store.persistAppliedChange(appliedChange(type: .genreUpdate))
        try await store.persistAppliedChange(appliedChange(type: .yearUpdate))
        try await store.persistAppliedChange(appliedChange(type: .artistRename))
        try await store.persistAppliedChange(appliedChange(type: .albumCleaning))

        let refreshedTrack = Track(
            id: "T001",
            name: "Refreshed Song",
            artist: "Canonical Artist",
            album: "Clean Album",
            genre: "Metal",
            year: 2024,
            originalArtist: "Injected Artist",
            originalAlbum: "Injected Album",
            yearBeforeMGU: 1901,
            yearSetByMGU: 1902,
            appleScriptID: "T001"
        )
        let insertedTrack = Track(
            id: "T003",
            name: "Inserted Song",
            artist: "Test Artist",
            album: "Test Album",
            originalArtist: "Injected Artist",
            originalAlbum: "Injected Album",
            yearBeforeMGU: 1901,
            yearSetByMGU: 1902,
            appleScriptID: "T003"
        )
        let revision = try await store.loadMirrorSnapshot().revision
        let presentIDs = try [databaseID("T001"), databaseID("T003")]

        try await store.applyMirror(TrackMirrorUpdate(
            baseRevision: revision,
            coverageChange: .preserve,
            membershipChange: replacementMembership(for: presentIDs),
            repairs: [],
            upserts: [refreshedTrack, insertedTrack]
        ))

        let loadedTracks = try await store.loadAllTracks()
        #expect(loadedTracks.map(\.id).sorted() == ["T001", "T003"])
        let refreshed = try #require(loadedTracks.first { $0.id == "T001" })
        #expect(refreshed.name == "Refreshed Song")
        #expect(refreshed.originalArtist == "Test Artist")
        #expect(refreshed.originalAlbum == "Test Album")
        #expect(refreshed.yearBeforeMGU == 2020)
        #expect(refreshed.yearSetByMGU == 2024)
        let inserted = try #require(loadedTracks.first { $0.id == "T003" })
        #expect(inserted.originalArtist == nil)
        #expect(inserted.originalAlbum == nil)
        #expect(inserted.yearBeforeMGU == nil)
        #expect(inserted.yearSetByMGU == nil)
        let unprocessedIDs = try await store.getUnprocessedTracks().map(\.id)
        #expect(!unprocessedIDs.contains("T001"))
        #expect(unprocessedIDs.contains("T003"))
    }

    @Test("Mirror apply rejects duplicate upserts without changing stored state")
    func applyMirrorRejectsDuplicateUpserts() async throws {
        let store = try makeStore()
        try await store.seedMirror([sampleTrack(id: "T001"), sampleTrack(id: "T002")])
        let before = try await store.loadAllTracks()
        let duplicateID = try databaseID("T001")
        let revision = try await store.loadMirrorSnapshot().revision

        do {
            try await store.applyMirror(TrackMirrorUpdate(
                baseRevision: revision,
                coverageChange: .preserve,
                membershipChange: .preserve,
                repairs: [],
                upserts: [mirrorTrack(id: "T001", name: "First"), mirrorTrack(id: "T001", name: "Second")]
            ))
            Issue.record("Expected duplicate mirror upserts to fail")
        } catch let error as TrackStoreError {
            #expect(error == .duplicateUpserts(ids: [duplicateID]))
        }

        #expect(try await store.loadAllTracks() == before)
    }

    @Test("Mirror apply rejects duplicate membership IDs without changing stored state")
    func rejectsDuplicateMembership() async throws {
        let store = try makeStore()
        try await store.seedMirror([sampleTrack(id: "T001"), sampleTrack(id: "T002")])
        let before = try await store.loadAllTracks()
        let duplicateID = try databaseID("T002")
        let stamp = try MembershipFingerprint.make(ids: [duplicateID])
        let revision = try await store.loadMirrorSnapshot().revision

        do {
            try await store.applyMirror(TrackMirrorUpdate(
                baseRevision: revision,
                coverageChange: .preserve,
                membershipChange: .replace(
                    stamp: stamp,
                    ids: [duplicateID, duplicateID],
                    observedAt: .now
                ),
                repairs: [],
                upserts: []
            ))
            Issue.record("Expected duplicate membership IDs to fail")
        } catch let error as TrackStoreError {
            #expect(error == .duplicateMembershipIDs(ids: [duplicateID]))
        }

        #expect(try await store.loadAllTracks() == before)
    }

    @Test("Mirror apply rejects an upsert outside current membership")
    func rejectsNonmemberUpsert() async throws {
        let store = try makeStore()
        try await store.seedMirror([sampleTrack(id: "T001"), sampleTrack(id: "T002")])
        let before = try await store.loadAllTracks()
        let targetID = try databaseID("T001")
        let revision = try await store.loadMirrorSnapshot().revision

        do {
            try await store.applyMirror(TrackMirrorUpdate(
                baseRevision: revision,
                coverageChange: .preserve,
                membershipChange: replacementMembership(for: [databaseID("T002")]),
                repairs: [],
                upserts: [mirrorTrack(id: "T001", name: "Updated")]
            ))
            Issue.record("Expected a nonmember upsert to fail")
        } catch let error as TrackStoreError {
            #expect(error == .operationsOutsideMembership(ids: [targetID]))
        }

        #expect(try await store.loadAllTracks() == before)
    }

    @Test("Mirror apply rejects an upsert without canonical database identity")
    func applyMirrorRejectsMissingDatabaseID() async throws {
        let store = try makeStore()
        try await store.seedMirror([sampleTrack(id: "T001")])
        let before = try await store.loadAllTracks()
        let revision = try await store.loadMirrorSnapshot().revision

        do {
            try await store.applyMirror(TrackMirrorUpdate(
                baseRevision: revision,
                coverageChange: .preserve,
                membershipChange: .preserve,
                repairs: [],
                upserts: [sampleTrack(id: "T001")]
            ))
            Issue.record("Expected missing mirror database identity to fail")
        } catch let error as TrackStoreError {
            #expect(error == .missingDatabaseID(trackID: "T001"))
        }

        #expect(try await store.loadAllTracks() == before)
    }

    @Test("Mirror apply rejects different presentation and database identities")
    func applyMirrorRejectsIdentityMismatch() async throws {
        let store = try makeStore()
        try await store.seedMirror([sampleTrack(id: "T001")])
        let before = try await store.loadAllTracks()
        var mismatchedTrack = sampleTrack(id: "MUSIC-KIT-ID")
        mismatchedTrack.appleScriptID = "T001"
        let databaseID = try databaseID("T001")
        let revision = try await store.loadMirrorSnapshot().revision

        do {
            try await store.applyMirror(TrackMirrorUpdate(
                baseRevision: revision,
                coverageChange: .preserve,
                membershipChange: .preserve,
                repairs: [],
                upserts: [mismatchedTrack]
            ))
            Issue.record("Expected mismatched mirror identities to fail")
        } catch let error as TrackStoreError {
            #expect(error == .nonCanonicalTrack(
                trackID: "MUSIC-KIT-ID",
                databaseID: databaseID
            ))
        }

        #expect(try await store.loadAllTracks() == before)
    }

    @Test("Mirror apply rejects a canonical upsert colliding with a noncanonical row")
    func applyMirrorRejectsIdentityCollision() async throws {
        let store = try makeNoncanonicalFixture(id: "catalog").store
        let before = try await store.loadAllTracks()
        let databaseID = try databaseID("catalog")
        let revision = try await store.loadMirrorSnapshot().revision

        do {
            try await store.applyMirror(TrackMirrorUpdate(
                baseRevision: revision,
                coverageChange: .preserve,
                membershipChange: .preserve,
                repairs: [],
                upserts: [mirrorTrack(id: "catalog", name: "Canonical")]
            ))
            Issue.record("Expected canonical mirror identity collision to fail")
        } catch let error as TrackStoreError {
            #expect(error == .identityCollisions(ids: [databaseID]))
        }

        #expect(try await store.loadAllTracks() == before)
    }

    @Test("Mirror membership may classify an ID without processing metadata")
    func membershipAllowsMetadataGap() async throws {
        let fixture = try makeNoncanonicalFixture(id: "catalog")
        let store = fixture.store
        let databaseID = try databaseID("catalog")
        let revision = try await store.loadMirrorSnapshot().revision

        try await store.applyMirror(TrackMirrorUpdate(
            baseRevision: revision,
            coverageChange: .preserve,
            membershipChange: replacementMembership(for: [databaseID]),
            repairs: [],
            upserts: []
        ))

        #expect(try presentIDs(in: fixture.container) == [databaseID])
        #expect(try await store.loadAllTracks().isEmpty)
        #expect(try await store.getUnprocessedTracks().isEmpty)
    }

    @Test("Mirror snapshot separates present library rows from legacy repair candidates")
    func separatesMirrorFacets() async throws {
        let container = try makeMemoryContainer()
        let context = ModelContext(container)
        let presentIDs = try (0 ..< 201).map { try databaseID("database-\($0)") }
        let stamp = try MembershipFingerprint.make(ids: presentIDs)
        for presentID in presentIDs {
            context.insert(PersistedTrack(
                trackID: presentID.rawValue,
                appleScriptID: presentID.rawValue,
                name: "Only for the Weak",
                artist: "In Flames",
                album: "Clayman"
            ))
            context.insert(PersistedLibraryMember(
                databaseID: presentID.rawValue,
                isPresent: true,
                firstSeenRevisionValue: MirrorRevision.initial.value,
                lastSeenFingerprint: stamp.fingerprint
            ))
        }
        for index in 0 ..< 403 {
            context.insert(PersistedTrack(
                trackID: "catalog-\(index)",
                appleScriptID: presentIDs[index % presentIDs.count].rawValue,
                name: "Only for the Weak",
                artist: "In Flames",
                album: "Clayman"
            ))
        }
        try context.save()

        let snapshot = try await TrackDataStore(modelContainer: container).loadMirrorSnapshot()

        #expect(snapshot.presentTracks.count == 201)
        #expect(snapshot.repairCandidates.count == 403)
        #expect(snapshot.membershipStamp == stamp)
    }

    @Test("Mirror repair preserves state and repairs linked and unlinked history")
    func mirrorRepairPreservesStateAndHistory() async throws {
        let container = try makeMemoryContainer()
        let context = ModelContext(container)
        let processedAt = Date(timeIntervalSince1970: 1_700_100_000)
        let (legacy, linked, unlinked) = makeLegacyFixture(processedAt: processedAt)
        context.insert(legacy)
        context.insert(linked)
        context.insert(unlinked)
        try context.save()
        let persistentID = legacy.persistentModelID

        let target = Track(
            id: "database-id",
            name: "Canonical Name",
            artist: "Canonical Artist",
            album: "Canonical Album",
            genre: "Metal",
            year: 2001,
            dateAdded: Date(timeIntervalSince1970: 1_600_000_000),
            trackStatus: "matched",
            originalArtist: "Injected Artist",
            originalAlbum: "Injected Album",
            yearBeforeMGU: 1901,
            yearSetByMGU: 1902,
            releaseYear: 2000,
            albumArtist: "Canonical Album Artist",
            appleScriptID: "database-id"
        )
        let update = try TrackMirrorUpdate(
            baseRevision: .initial,
            coverageChange: .preserve,
            membershipChange: replacementMembership(for: [databaseID("database-id")]),
            repairs: [TrackMirrorRepair(sourceID: "catalog-id", target: target)],
            upserts: []
        )

        let store = TrackDataStore(modelContainer: container)
        try await store.applyMirror(update)

        let verification = ModelContext(container)
        let tracks = try verification.fetch(FetchDescriptor<PersistedTrack>())
        let repaired = try #require(tracks.first)
        #expect(tracks.count == 1)
        expectRepairedTrack(
            repaired,
            hasSameIdentity: repaired.persistentModelID == persistentID,
            processedAt: processedAt
        )

        let history = try verification.fetch(FetchDescriptor<PersistedChangeLogEntry>())
        #expect(history.count == 2)
        #expect(history.allSatisfy { $0.trackID == "database-id" })
        #expect(history.first { $0.entryID == linked.entryID }?.track?.persistentModelID == persistentID)
        #expect(history.first { $0.entryID == unlinked.entryID }?.track?.persistentModelID == persistentID)
    }

    @Test("Mirror repair converges canonical and legacy state with all history")
    func repairConvergesCanonicalTarget() async throws {
        let container = try makeMemoryContainer()
        let context = ModelContext(container)
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        let later = Date(timeIntervalSince1970: 1_800_000_000)
        let canonical = PersistedTrack(
            trackID: "AS1", appleScriptID: "AS1", name: "Stored", artist: "Stored", album: "Stored",
            genreUpdated: true, processedDate: earlier, lastError: "canonical error", originalArtist: "Stored Artist"
        )
        let legacy = PersistedTrack(
            trackID: "MK1", appleScriptID: "AS1", name: "Legacy", artist: "Legacy", album: "Legacy",
            yearUpdated: true, processedDate: later, lastError: "legacy error", originalAlbum: "Legacy Album",
            yearBeforeMGU: 1998, yearSetByMGU: 1999
        )
        let canonicalHistory = PersistedChangeLogEntry(
            entryID: UUID(), timestamp: .now, changeTypeRaw: ChangeType.genreUpdate.rawValue,
            trackID: "AS1", artist: "Stored", trackName: "Stored", albumName: "Stored"
        )
        canonicalHistory.track = canonical
        let linkedLegacyHistory = PersistedChangeLogEntry(
            entryID: UUID(), timestamp: .now, changeTypeRaw: ChangeType.yearUpdate.rawValue,
            trackID: "MK1", artist: "Legacy", trackName: "Legacy", albumName: "Legacy"
        )
        linkedLegacyHistory.track = legacy
        let unlinkedLegacyHistory = PersistedChangeLogEntry(
            entryID: UUID(), timestamp: .now, changeTypeRaw: ChangeType.artistRename.rawValue,
            trackID: "MK1", artist: "Legacy", trackName: "Legacy", albumName: "Legacy"
        )
        context.insert(canonical)
        context.insert(legacy)
        context.insert(canonicalHistory)
        context.insert(linkedLegacyHistory)
        context.insert(unlinkedLegacyHistory)
        try context.save()

        let live = Track(
            id: "AS1", name: "Live", artist: "Live", album: "Live", appleScriptID: "AS1"
        )
        let update = try TrackMirrorUpdate(
            baseRevision: .initial,
            coverageChange: .preserve,
            membershipChange: replacementMembership(for: [databaseID("AS1")]),
            repairs: [TrackMirrorRepair(sourceID: "MK1", target: live)],
            upserts: []
        )
        let store = TrackDataStore(modelContainer: container)

        try await store.applyMirror(update)
        try await store.applyMirror(TrackMirrorUpdate(
            baseRevision: MirrorRevision(value: 1),
            coverageChange: update.coverageChange,
            membershipChange: update.membershipChange,
            repairs: update.repairs,
            upserts: update.upserts
        ))

        let verification = ModelContext(container)
        let tracks = try verification.fetch(FetchDescriptor<PersistedTrack>())
        let history = try verification.fetch(FetchDescriptor<PersistedChangeLogEntry>())
        let merged = try #require(tracks.first)
        #expect(tracks.count == 1)
        expectMergedTrack(merged, processedAt: later)
        #expect(history.count == 3)
        #expect(history.allSatisfy { $0.trackID == "AS1" && $0.track?.trackID == "AS1" })
    }

    @Test("Mirror repair validation leaves stored state unchanged")
    func mirrorRepairValidationIsAtomic() async throws {
        let container = try makeMemoryContainer()
        let context = ModelContext(container)
        context.insert(PersistedTrack(
            trackID: "legacy", appleScriptID: "legacy", name: "Legacy", artist: "Artist", album: "Album"
        ))
        context.insert(PersistedTrack(trackID: "occupied", name: "Occupied", artist: "Artist", album: "Album"))
        try context.save()
        let store = TrackDataStore(modelContainer: container)
        let before = try await store.loadAllTracks()
        let target = mirrorTrack(id: "target")
        let occupied = mirrorTrack(id: "occupied")
        let revision = try await store.loadMirrorSnapshot().revision
        let cases = repairValidationCases(
            revision: revision,
            target: target,
            occupied: occupied,
            other: mirrorTrack(id: "other"),
            legacy: mirrorTrack(id: "legacy")
        )

        for (update, expectedError) in cases {
            await #expect(throws: expectedError) {
                try await store.applyMirror(update)
            }
            #expect(try await store.loadAllTracks() == before)
        }
    }

    @Test("Mirror update atomically combines rekey, upsert, and tombstone")
    func mixedMirrorUpdate() async throws {
        let store = try makeStore()
        try await store.seedMirror([
            sampleTrack(id: "legacy"),
            mirrorTrack(id: "updated", name: "Old"),
            mirrorTrack(id: "deleted"),
        ])
        let revision = try await store.loadMirrorSnapshot().revision
        let update = try TrackMirrorUpdate(
            baseRevision: revision,
            coverageChange: .preserve,
            membershipChange: replacementMembership(for: [
                databaseID("inserted"),
                databaseID("rekeyed"),
                databaseID("updated"),
            ]),
            repairs: [TrackMirrorRepair(sourceID: "legacy", target: mirrorTrack(id: "rekeyed"))],
            upserts: [mirrorTrack(id: "updated", name: "New"), mirrorTrack(id: "inserted")]
        )

        try await store.applyMirror(update)

        let tracks = try await store.loadAllTracks()
        #expect(tracks.map(\.id).sorted() == ["inserted", "rekeyed", "updated"])
        #expect(tracks.first { $0.id == "updated" }?.name == "New")
    }

    @Test("Legacy populated rows survive relaunch with unknown coverage")
    func legacyRowsStayUnready() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackMirrorMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tracks.store")

        do {
            let container = try makeLegacyContainer(at: url)
            let context = ModelContext(container)
            context.insert(PersistedTrack(
                trackID: "legacy",
                appleScriptID: "legacy",
                name: "Song",
                artist: "Artist",
                album: "Album"
            ))
            try context.save()
        }

        do {
            let migrated = try TrackDataStore(modelContainer: makeContainer(at: url))
            try await migrated.initialize()
            let snapshot = try await migrated.loadMirrorSnapshot()
            #expect(snapshot.presentTracks.map(\.id) == ["legacy"])
            #expect(snapshot.coverage == .unknown)
        }

        let relaunched = try TrackDataStore(modelContainer: makeContainer(at: url))
        try await relaunched.initialize()
        let snapshot = try await relaunched.loadMirrorSnapshot()
        #expect(snapshot.presentTracks.map(\.id) == ["legacy"])
        #expect(snapshot.coverage == .unknown)
    }

    @Test("A legacy empty store migrates to unknown mirror coverage")
    func legacyEmptyIsUnknown() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackMirrorEmptyMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tracks.store")

        _ = try makeLegacyContainer(at: url)

        let migrated = try TrackDataStore(modelContainer: makeContainer(at: url))
        try await migrated.initialize()
        let snapshot = try await migrated.loadMirrorSnapshot()
        #expect(snapshot.presentTracks.isEmpty)
        #expect(snapshot.coverage == .unknown)
    }

    @Test("Mirror repair and undo evidence survive relaunch")
    func mirrorRepairSurvivesRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackMirrorRepair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tracks.store")
        let entryID = UUID()

        do {
            let container = try makeContainer(at: url)
            let context = ModelContext(container)
            let canonical = PersistedTrack(
                trackID: "canonical", appleScriptID: "canonical", name: "Stored", artist: "Artist", album: "Album",
                lastError: "stored error", originalArtist: "Stored Artist"
            )
            let legacy = PersistedTrack(
                trackID: "legacy", appleScriptID: "canonical", name: "Legacy", artist: "Artist", album: "Album",
                genreUpdated: true, originalArtist: "Original"
            )
            let entry = PersistedChangeLogEntry(
                entryID: entryID, timestamp: .now, changeTypeRaw: ChangeType.artistRename.rawValue,
                trackID: "legacy", artist: "Artist", trackName: "Legacy", albumName: "Album"
            )
            entry.track = legacy
            context.insert(canonical)
            context.insert(legacy)
            context.insert(entry)
            try context.save()
            try await TrackDataStore(modelContainer: container).applyMirror(TrackMirrorUpdate(
                baseRevision: .initial,
                coverageChange: .preserve,
                membershipChange: replacementMembership(for: [databaseID("canonical")]),
                repairs: [TrackMirrorRepair(sourceID: "legacy", target: mirrorTrack(id: "canonical"))],
                upserts: []
            ))
        }

        let relaunched = try makeContainer(at: url)
        let context = ModelContext(relaunched)
        let tracks = try context.fetch(FetchDescriptor<PersistedTrack>())
        let track = try #require(tracks.first)
        let entry = try #require(context.fetch(FetchDescriptor<PersistedChangeLogEntry>()).first)
        #expect(tracks.count == 1)
        #expect(track.trackID == "canonical")
        #expect(track.genreUpdated)
        #expect(track.lastError == "stored error")
        #expect(track.originalArtist == "Stored Artist")
        #expect(entry.entryID == entryID)
        #expect(entry.trackID == "canonical")
        #expect(entry.track?.trackID == "canonical")
    }
}
