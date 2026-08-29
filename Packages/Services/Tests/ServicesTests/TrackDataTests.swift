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

    private func makeStore(at url: URL) throws -> TrackDataStore {
        try TrackDataStore(modelContainer: makeContainer(at: url))
    }

    private func makeContainer(at url: URL) throws -> ModelContainer {
        let schema = Schema([
            PersistedTrack.self,
            PersistedLibraryMember.self,
            PersistedMirrorState.self,
            PersistedChangeLogEntry.self,
        ])
        let configuration = ModelConfiguration(
            "TrackRecoveryRelaunch",
            schema: schema,
            url: url,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
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

    private func databaseID(_ rawValue: String) throws -> MusicDatabaseTrackID {
        try #require(MusicDatabaseTrackID(rawValue: rawValue))
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
        try await store.seedMirror(tracks)

        let loaded = try await store.loadMirrorSnapshot().presentTracks
        #expect(loaded.count == 2)
    }

    @Test("getTrack by ID returns correct track")
    func getTrackByID() async throws {
        let store = try makeStore()
        try await store.initialize()

        try await store.seedMirror([sampleTrack(id: "ABC")])

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

        try await store.seedMirror([sampleTrack(id: "1"), sampleTrack(id: "2"), sampleTrack(id: "3")])
        #expect(try await store.trackCount() == 3)
    }

    @Test("Mirror membership hides removed tracks from current reads")
    func hidesRemovedTracks() async throws {
        let store = try makeStore()
        try await store.initialize()

        try await store.seedMirror([
            sampleTrack(id: "1"),
            sampleTrack(id: "2"),
            sampleTrack(id: "3"),
        ])
        let remainingIDs = try [databaseID("1"), databaseID("3")]
        let revision = try await store.loadMirrorSnapshot().revision

        try await store.commitMirror(MirrorCommit(
            baseRevision: revision,
            inventoryChange: replacementInventory(for: remainingIDs),
            repairs: [],
            upserts: [],
            certificates: .invalidate(.membershipChanged)
        ))
        let remainingTracks = try await store.loadMirrorSnapshot().presentTracks
        let loadedIDs = remainingTracks.map(\.id).sorted()

        #expect(loadedIDs == ["1", "3"])
    }

    @Test("Mirror compare-and-swap rejects a stale base without partial rows")
    func mirrorCompareAndSwapRejectsStaleBase() async throws {
        let store = try makeStore()
        try await store.initialize()
        var acceptedTrack = sampleTrack(id: "accepted")
        acceptedTrack.appleScriptID = acceptedTrack.id
        var rejectedTrack = sampleTrack(id: "rejected")
        rejectedTrack.appleScriptID = rejectedTrack.id

        let committedRevision = try await store.commitMirror(MirrorCommit(
            baseRevision: .initial,
            inventoryChange: replacementInventory(for: [acceptedTrack]),
            repairs: [],
            upserts: [acceptedTrack],
            certificates: .invalidate(.membershipChanged)
        ))

        #expect(committedRevision.revision == MirrorRevision(value: 1))
        do {
            _ = try await store.commitMirror(MirrorCommit(
                baseRevision: .initial,
                inventoryChange: replacementInventory(for: [rejectedTrack]),
                repairs: [],
                upserts: [rejectedTrack],
                certificates: .invalidate(.incompleteObservation)
            ))
            Issue.record("A stale mirror update unexpectedly committed")
        } catch let conflict as MirrorRevisionConflict {
            #expect(conflict == MirrorRevisionConflict(
                expected: .initial,
                actual: MirrorRevision(value: 1)
            ))
        }

        let snapshot = try await store.loadMirrorSnapshot()
        #expect(snapshot.revision == MirrorRevision(value: 1))
        #expect(snapshot.certificates.isEmpty)
        #expect(snapshot.presentTracks.map(\.id) == ["accepted"])
    }

    // MARK: - Upsert

    @Test("Mirror upsert updates an existing track")
    func updatesExistingMirror() async throws {
        let store = try makeStore()
        try await store.initialize()

        let original = Track(id: "U1", name: "Original", artist: "A", album: "B")
        try await store.seedMirror([original])

        let updated = Track(id: "U1", name: "Updated", artist: "A", album: "B", genre: "Metal")
        try await store.seedMirror([updated])

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
            try await store.seedMirror([sampleTrack()])

            try await store.commitAppliedChange(appliedChange(type: expectation.type))

            let stored = try #require(try await store.getTrack(byID: "T001"))
            #expect(stored.name == expectation.name)
            #expect(stored.artist == expectation.artist)
            #expect(stored.album == expectation.album)
            #expect(stored.genre == expectation.genre)
            #expect(stored.year == expectation.year)
        }
    }

    @Test("Coupled artist rename updates both fields in the persisted mirror")
    func coupledArtistRenameUpdatesPersistedMirror() async throws {
        let store = try makeStore()
        try await store.seedMirror([
            Track(
                id: "T001",
                name: "Teardrop",
                artist: "Massive",
                album: "Mezzanine",
                albumArtist: "Massive"
            ),
        ])
        var change = ChangeLogEntry(
            changeType: .artistRename,
            trackID: "T001",
            artist: "Massive",
            trackName: "Teardrop",
            albumName: "Mezzanine"
        )
        change.oldArtist = "Massive"
        change.newArtist = "Massive Attack"
        change.albumArtistChange = AlbumArtistChange(
            oldValue: "Massive",
            newValue: "Massive Attack"
        )

        try await store.commitAppliedChange(change)

        let stored = try #require(try await store.getTrack(byID: "T001"))
        #expect(stored.artist == "Massive Attack")
        #expect(stored.albumArtist == "Massive Attack")
    }

    @Test("Applied change commits mirror, membership, history, and revision once")
    func commitsAppliedChangeOnce() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = TrackDataStore(modelContainer: container)
        try await store.initialize()
        try await store.seedMirror([
            Track(
                id: "T001",
                name: "Teardrop",
                artist: "Massive",
                album: "Mezzanine",
                albumArtist: "Massive"
            ),
        ])
        let changeID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let change = ChangeLogEntry(
            id: changeID,
            timestamp: timestamp,
            changeType: .artistRename,
            trackID: "T001",
            artist: "Massive",
            trackName: "Teardrop",
            albumName: "Mezzanine",
            oldArtist: "Massive",
            newArtist: "Massive Attack",
            albumArtistChange: AlbumArtistChange(oldValue: "Massive", newValue: "Massive Attack")
        )

        try await store.commitAppliedChange(change)
        try await store.commitAppliedChange(change)

        let snapshot = try await store.loadMirrorSnapshot()
        let context = ModelContext(container)
        let history = try context.fetch(FetchDescriptor<PersistedChangeLogEntry>())
        let member = try #require(context.fetch(FetchDescriptor<PersistedLibraryMember>()).first)

        #expect(snapshot.revision == MirrorRevision(value: 2))
        #expect(snapshot.presentTracks.first?.artist == "Massive Attack")
        #expect(snapshot.presentTracks.first?.albumArtist == "Massive Attack")
        #expect(history.map(\.entryID) == [changeID])
        #expect(member.artist == "Massive Attack")
        #expect(member.albumArtist == "Massive Attack")
        #expect(member.identityObservedAt == timestamp)
        #expect(member.identityRevisionValue == 2)
    }

    @Test("Existing history repairs an unfinished mirror finalization once")
    func repairsHistoricSplitFinalization() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = TrackDataStore(modelContainer: container)
        try await store.initialize()
        try await store.seedMirror([sampleTrack()])
        let change = ChangeLogEntry(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            changeType: .yearUpdate,
            trackID: "T001",
            artist: "Test Artist",
            trackName: "Test Song",
            albumName: "Test Album",
            oldYear: 2020,
            newYear: 2024
        )
        let context = ModelContext(container)
        context.insert(PersistedChangeLogEntry(from: change))
        try context.save()

        _ = try await store.commitAppliedChange(change)
        _ = try await store.commitAppliedChange(change)

        let snapshot = try await store.loadMirrorSnapshot()
        let history = try context.fetch(FetchDescriptor<PersistedChangeLogEntry>())
        #expect(snapshot.revision == MirrorRevision(value: 2))
        #expect(snapshot.presentTracks.first?.year == 2024)
        #expect(history.map(\.entryID) == [change.id])
    }

    @Test("Recovery canonicalizes same-event legacy history atomically")
    func canonicalizesLegacyHistory() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = TrackDataStore(modelContainer: container)
        try await store.initialize()
        try await store.seedMirror([sampleTrack()])
        let changeID = UUID()
        let runID = UUID()
        var legacy = ChangeLogEntry(
            id: changeID,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            changeType: .genreUpdate,
            trackID: "music-kit-1",
            artist: "Test Artist",
            trackName: "Test Song",
            albumName: "Test Album",
            oldGenre: "Rock",
            newGenre: "Metal"
        )
        legacy.runID = runID
        var canonical = ChangeLogEntry(
            id: changeID,
            timestamp: legacy.timestamp,
            changeType: legacy.changeType,
            trackID: "T001",
            artist: legacy.artist,
            trackName: legacy.trackName,
            albumName: legacy.albumName,
            oldGenre: legacy.oldGenre,
            newGenre: legacy.newGenre
        )
        canonical.runID = runID
        let context = ModelContext(container)
        context.insert(PersistedChangeLogEntry(from: legacy))
        try context.save()

        _ = try await store.commitAppliedChange(canonical)
        _ = try await store.commitAppliedChange(canonical)

        let snapshot = try await store.loadMirrorSnapshot()
        let history = try context.fetch(FetchDescriptor<PersistedChangeLogEntry>())
        #expect(snapshot.revision == MirrorRevision(value: 2))
        #expect(snapshot.presentTracks.first?.genre == "Metal")
        #expect(history.map(\.entryID) == [changeID])
        #expect(history.map(\.trackID) == ["T001"])
    }

    @Test("Genre and year writes complete processing state")
    func completesProcessingState() async throws {
        let store = try makeStore()
        try await store.initialize()
        try await store.seedMirror([sampleTrack()])

        try await store.commitAppliedChange(appliedChange(type: .genreUpdate))
        try await store.commitAppliedChange(appliedChange(type: .yearUpdate))

        #expect(try await store.getUnprocessedTracks().isEmpty)
    }

    @Test("Confirmed writes persist recovery metadata")
    func persistsRecoveryMetadata() async throws {
        let store = try makeStore()
        try await store.seedMirror([sampleTrack()])

        try await store.commitAppliedChange(appliedChange(type: .yearUpdate))
        try await store.commitAppliedChange(appliedChange(type: .artistRename))
        try await store.commitAppliedChange(appliedChange(type: .albumCleaning))

        let stored = try #require(try await store.getTrack(byID: "T001"))
        #expect(stored.yearBeforeMGU == 2020)
        #expect(stored.yearSetByMGU == 2024)
        #expect(stored.originalArtist == "Test Artist")
        #expect(stored.originalAlbum == "Test Album")
        #expect(stored.hasBeenProcessed)
    }

    @Test("Repeated writes preserve first originals and update the applied year")
    func preservesFirstValues() async throws {
        let store = try makeStore()
        try await store.seedMirror([sampleTrack()])

        try await store.commitAppliedChange(appliedChange(type: .yearUpdate))
        var secondYear = appliedChange(type: .yearUpdate)
        secondYear.oldYear = 2024
        secondYear.newYear = 2025
        try await store.commitAppliedChange(secondYear)

        try await store.commitAppliedChange(appliedChange(type: .artistRename))
        var secondArtist = appliedChange(type: .artistRename)
        secondArtist.oldArtist = "Canonical Artist"
        secondArtist.newArtist = "Final Artist"
        try await store.commitAppliedChange(secondArtist)

        try await store.commitAppliedChange(appliedChange(type: .albumCleaning))
        var secondAlbum = appliedChange(type: .albumCleaning)
        secondAlbum.oldAlbumName = "Clean Album"
        secondAlbum.newAlbumName = "Final Album"
        try await store.commitAppliedChange(secondAlbum)

        let stored = try #require(try await store.getTrack(byID: "T001"))
        #expect(stored.yearBeforeMGU == 2020)
        #expect(stored.yearSetByMGU == 2025)
        #expect(stored.originalArtist == "Test Artist")
        #expect(stored.originalAlbum == "Test Album")
    }

    @Test("Sparse library refresh preserves recovery metadata")
    func sparseRefreshPreservesState() async throws {
        let store = try makeStore()
        try await store.seedMirror([sampleTrack()])
        try await store.commitAppliedChange(appliedChange(type: .yearUpdate))
        try await store.commitAppliedChange(appliedChange(type: .artistRename))
        try await store.commitAppliedChange(appliedChange(type: .albumCleaning))

        let sparseRefresh = Track(
            id: "T001",
            name: "Test Song",
            artist: "Canonical Artist",
            album: "Clean Album",
            year: 2024
        )
        try await store.seedMirror([sparseRefresh])

        let stored = try #require(try await store.getTrack(byID: "T001"))
        #expect(stored.originalArtist == "Test Artist")
        #expect(stored.originalAlbum == "Test Album")
        #expect(stored.yearBeforeMGU == 2020)
        #expect(stored.yearSetByMGU == 2024)
    }

    @Test("Recovery metadata survives store relaunch")
    func survivesRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackRecoveryRelaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("Failed to remove relaunch fixture: \(error)")
            }
        }
        let storeURL = directory.appendingPathComponent("GenreUpdater.store")

        do {
            let store = try makeStore(at: storeURL)
            try await store.seedMirror([sampleTrack()])
            try await store.commitAppliedChange(appliedChange(type: .yearUpdate))
            try await store.commitAppliedChange(appliedChange(type: .artistRename))
            try await store.commitAppliedChange(appliedChange(type: .albumCleaning))
        }

        let relaunchedStore = try makeStore(at: storeURL)
        let stored = try #require(try await relaunchedStore.getTrack(byID: "T001"))
        #expect(stored.yearBeforeMGU == 2020)
        #expect(stored.yearSetByMGU == 2024)
        #expect(stored.originalArtist == "Test Artist")
        #expect(stored.originalAlbum == "Test Album")
        #expect(stored.hasBeenProcessed)
    }

    @Test("Persisted track construction normalizes current zero years")
    func normalizesPersistedZeros() {
        let persisted = PersistedTrack(
            trackID: "T001",
            name: "Angel",
            artist: "Massive Attack",
            album: "Mezzanine",
            year: 0,
            yearBeforeMGU: 0,
            yearSetByMGU: 0,
            releaseYear: 0
        )

        #expect(persisted.year == nil)
        #expect(persisted.releaseYear == nil)
        #expect(persisted.yearBeforeMGU == 0)
        #expect(persisted.yearSetByMGU == 0)
    }

    @Test("Initialization durably repairs stored current zero years")
    func repairsStoredZeros() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackZeroYearRepair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("Failed to remove zero-year repair fixture: \(error)")
            }
        }
        let storeURL = directory.appendingPathComponent("GenreUpdater.store")

        do {
            let container = try makeContainer(at: storeURL)
            let context = ModelContext(container)
            let missingYear = PersistedTrack(
                trackID: "T001",
                name: "Angel",
                artist: "Massive Attack",
                album: "Mezzanine",
                year: 1998,
                yearBeforeMGU: 1996,
                yearSetByMGU: 2003,
                releaseYear: 1998
            )
            let missingReleaseYear = PersistedTrack(
                trackID: "T002",
                name: "Teardrop",
                artist: "Massive Attack",
                album: "Mezzanine",
                year: 2004,
                yearBeforeMGU: 1997,
                yearSetByMGU: 2004,
                releaseYear: 2007
            )
            context.insert(missingYear)
            context.insert(missingReleaseYear)
            missingYear.year = 0
            missingReleaseYear.releaseYear = 0
            try context.save()
        }

        do {
            let store = try makeStore(at: storeURL)
            try await store.initialize()
        }

        let relaunchedContainer = try makeContainer(at: storeURL)
        let context = ModelContext(relaunchedContainer)
        let rows = try context.fetch(FetchDescriptor<PersistedTrack>())
        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.trackID, $0) })
        let repairedYear = try #require(rowsByID["T001"])
        let repairedReleaseYear = try #require(rowsByID["T002"])

        #expect(repairedYear.year == nil)
        #expect(repairedYear.releaseYear == 1998)
        #expect(repairedYear.yearBeforeMGU == 1996)
        #expect(repairedYear.yearSetByMGU == 2003)
        #expect(repairedReleaseYear.year == 2004)
        #expect(repairedReleaseYear.releaseYear == nil)
        #expect(repairedReleaseYear.yearBeforeMGU == 1997)
        #expect(repairedReleaseYear.yearSetByMGU == 2004)
    }

    @Test("Applied change persistence fails when the track is missing")
    func rejectsMissingTrack() async throws {
        let store = try makeStore()
        try await store.initialize()

        await #expect(throws: TrackStoreError.self) {
            try await store.commitAppliedChange(appliedChange(trackID: "MISSING", type: .genreUpdate))
        }
    }

    @Test("Applied change persistence fails when the new value is missing")
    func rejectsMissingValue() async throws {
        let store = try makeStore()
        try await store.initialize()
        try await store.seedMirror([sampleTrack()])
        let change = ChangeLogEntry(
            changeType: .genreUpdate,
            trackID: "T001",
            artist: "Test Artist"
        )

        await #expect(throws: TrackChangeError.self) {
            try await store.commitAppliedChange(change)
        }
    }

    @Test("getUnprocessedTracks filters correctly")
    func unprocessedTracksFilter() async throws {
        let store = try makeStore()
        try await store.initialize()

        try await store.seedMirror([
            sampleTrack(id: "P1"),
            sampleTrack(id: "P2"),
            sampleTrack(id: "P3"),
        ])

        try await store.commitAppliedChange(appliedChange(trackID: "P1", type: .genreUpdate))
        try await store.commitAppliedChange(appliedChange(trackID: "P1", type: .yearUpdate))

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

        try await store.seedMirror(tracks)
        let count = try await store.trackCount()
        #expect(count == 600)
    }
}
