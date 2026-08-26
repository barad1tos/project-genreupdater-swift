import Core
import Foundation
import Testing
@testable import Services

@Suite("Library sync observation integration")
struct LibrarySyncObservationTests {
    private struct RowValues {
        var name: Observed<String> = .value("Song")
        var artist: Observed<String> = .value("Artist")
        var album: Observed<String> = .value("Album")
        var genre: Observed<String> = .value("Metal")
        var year: Observed<Int> = .value(2001)
        var releaseYear: Observed<Int> = .absent
        var albumArtist: Observed<String> = .absent
        var lastModified: Observed<Date> = .absent
    }

    @Test("Relaunch fast sync reuses the canonical persisted mirror")
    func reusesPersistedMirrorWithoutGeneration() async throws {
        let existing = mirrorTrack(id: "A", genre: "Metal")
        let store = ObservationMirrorStore(stored: [existing])
        let reader = try ObservationReader(templates: [template(
            currentIDs: ["A"],
            rows: [],
            metadataRequestedIDs: []
        )])
        let service = makeService(store: store, reader: reader)

        let result = try await service.detectObservation().result

        #expect(!result.hasChanges)
        let request = try #require(await reader.requests.first)
        guard case let .verified(mirror) = request.previous else {
            Issue.record("Expected the persisted mirror to back the fast observation")
            return
        }
        #expect(mirror.tracksByID.keys.map(\.rawValue).sorted() == ["A"])
        #expect(request.refresh == .fast)
    }

    @Test("Synchronize sorts its result and applies one atomic mirror delta")
    func appliesDeterministicAtomicDelta() async throws {
        let storedA = mirrorTrack(id: "A", genre: "Rock")
        let storedC = mirrorTrack(id: "C", genre: "Metal")
        let store = ObservationMirrorStore(stored: [storedC, storedA])
        let reader = try ObservationReader(templates: [template(
            currentIDs: ["B", "A"],
            rows: [
                row(id: "B", values: RowValues(genre: .value("Jazz"))),
                row(id: "A", values: RowValues(genre: .value("Alternative"))),
            ],
            metadataRequestedIDs: ["A", "B"]
        )])
        let service = makeService(store: store, reader: reader)

        let result = try await service.synchronizeNow(forceMetadataRefresh: true)

        #expect(result.newTracks.map(\.id) == ["B"])
        #expect(result.modifiedTracks.map(\.id) == ["A"])
        #expect(result.removedTrackIDs == ["C"])
        let call = try #require(await store.applyCalls.first)
        #expect(await store.applyCalls.count == 1)
        #expect(call.upserting.map(\.id) == ["A", "B"])
        #expect(call.deleting.map(\.rawValue) == ["C"])
    }

    @Test("Authoritative absence clears while unobserved metadata preserves")
    func reconcilesFieldObservationStates() async throws {
        let stored = mirrorTrack(
            id: "A",
            genre: "Metal",
            year: 2001,
            albumArtist: "Album Artist"
        )
        let store = ObservationMirrorStore(stored: [stored])
        let reader = try ObservationReader(templates: [template(
            currentIDs: ["A"],
            rows: [row(id: "A", values: RowValues(
                name: .unobserved(reason: "omitted"),
                genre: .absent,
                year: .unobserved(reason: "omitted"),
                albumArtist: .absent
            ))],
            metadataRequestedIDs: ["A"]
        )])
        let service = makeService(store: store, reader: reader)

        _ = try await service.synchronizeNow(forceMetadataRefresh: true)

        let persisted = try #require(await store.stored.first)
        #expect(persisted.name == stored.name)
        #expect(persisted.genre == nil)
        #expect(persisted.year == 2001)
        #expect(persisted.albumArtist == nil)
        #expect(persisted.originalArtist == stored.originalArtist)
        #expect(persisted.yearSetByMGU == stored.yearSetByMGU)
    }

    @Test("Authoritative year absence clears editable and release years")
    func clearsAbsentYears() async throws {
        let stored = Track(
            id: "A",
            name: "Song",
            artist: "Artist",
            album: "Album",
            year: 2001,
            releaseYear: 1999,
            appleScriptID: "A"
        )
        let store = ObservationMirrorStore(stored: [stored])
        let reader = try ObservationReader(templates: [template(
            currentIDs: ["A"],
            rows: [row(id: "A", values: RowValues(
                genre: .unobserved(reason: "omitted"),
                year: .absent,
                releaseYear: .absent
            ))],
            metadataRequestedIDs: ["A"]
        )])
        let service = makeService(store: store, reader: reader)

        _ = try await service.synchronizeNow(forceMetadataRefresh: true)

        let persisted = try #require(await store.stored.first)
        #expect(persisted.year == nil)
        #expect(persisted.releaseYear == nil)
    }

    @Test("Partial force observation does not advance its scan timestamp")
    func partialForceKeepsTimestamp() async throws {
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = SyncMockLibrarySnapshotService()
        await snapshot.setMetadata(cacheMetadata(lastForceScanDate: oldDate))
        let store = ObservationMirrorStore(stored: [mirrorTrack(id: "A", genre: "Rock")])
        let reader = try ObservationReader(templates: [template(
            currentIDs: ["A", "B"],
            rows: [row(id: "A", values: RowValues(genre: .value("Metal")))],
            metadataRequestedIDs: ["A", "B"],
            metadataObservedIDs: ["A"]
        )])
        let service = makeService(
            store: store,
            reader: reader,
            snapshot: snapshot,
            currentDate: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        _ = try await service.synchronizeNow(forceMetadataRefresh: true)

        #expect(await snapshot.getSnapshotMetadata()?.lastForceScanDate == oldDate)
    }

    @Test("A census-present stored row survives a missing metadata row")
    func preservesUnobservedRow() async throws {
        let stored = mirrorTrack(id: "A", genre: "Metal", year: 2001)
        let store = ObservationMirrorStore(stored: [stored])
        let reader = try ObservationReader(templates: [template(
            currentIDs: ["A"],
            rows: [],
            metadataRequestedIDs: ["A"],
            metadataObservedIDs: []
        )])
        let service = makeService(store: store, reader: reader)

        let result = try await service.synchronizeNow(forceMetadataRefresh: true)

        #expect(!result.hasChanges)
        #expect(await store.stored == [stored])
        let update = try #require(await store.applyCalls.first)
        #expect(update.upserting.isEmpty)
        #expect(update.deleting.isEmpty)
    }

    @Test("Timestamp-only metadata churn produces no sync delta")
    func ignoresTimestampOnlyChange() async throws {
        let stored = mirrorTrack(
            id: "A",
            genre: "Metal",
            year: 2001,
            lastModified: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let store = ObservationMirrorStore(stored: [stored])
        let reader = try ObservationReader(templates: [template(
            currentIDs: ["A"],
            rows: [row(id: "A", values: RowValues(
                lastModified: .value(Date(timeIntervalSince1970: 1_800_000_000))
            ))],
            metadataRequestedIDs: ["A"]
        )])
        let service = makeService(store: store, reader: reader)

        let result = try await service.detectObservation(forceMetadataRefresh: true).result

        #expect(!result.hasChanges)
    }

    @Test("Metadata requests outside the generation census fail closed")
    func rejectsMetadataOutsideCensus() async throws {
        let censusID = try databaseID("A")
        let foreignID = try databaseID("B")
        let generation = try #require(LibraryGeneration(sourceValue: "G1"))
        let store = ObservationMirrorStore(stored: [mirrorTrack(id: "A")])
        let reader = ObservationReader(templates: [ObservationTemplate(
            rows: [],
            censusIDs: [censusID],
            currentIDs: [censusID],
            membership: .full,
            requestedIDs: [foreignID],
            observedIDs: [],
            generation: generation
        )])
        let service = makeService(store: store, reader: reader)

        await #expect(throws: LibrarySyncObservationError.invalidObservation(
            detail: "metadata coverage does not match its rows"
        )) {
            _ = try await service.detectObservation()
        }
        #expect(await store.applyCalls.isEmpty)
    }

    @Test("New row with unobserved required text fails instead of disappearing")
    func rejectsIncompleteNewRow() async throws {
        let store = ObservationMirrorStore(stored: [])
        let reader = try ObservationReader(templates: [template(
            currentIDs: ["A"],
            rows: [row(id: "A", values: RowValues(name: .unobserved(reason: "omitted")))],
            metadataRequestedIDs: ["A"]
        )])
        let service = makeService(store: store, reader: reader)

        await #expect(throws: LibrarySyncObservationError.invalidObservation(
            detail: "Metadata row A omits required text"
        )) {
            _ = try await service.synchronizeNow(forceMetadataRefresh: true)
        }
        #expect(await store.applyCalls.isEmpty)
    }

    @Test("Missing force timestamp is not seeded by a fast sync")
    func doesNotSeedForceTimestampEarly() async throws {
        let snapshot = SyncMockLibrarySnapshotService()
        await snapshot.setMetadata(LibraryCacheMetadata(
            trackCount: 1,
            snapshotHash: "hash",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            libraryModificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        let store = ObservationMirrorStore(stored: [mirrorTrack(id: "A")])
        let reader = try ObservationReader(templates: [template(
            currentIDs: ["A"],
            rows: [],
            metadataRequestedIDs: []
        )])
        let service = makeService(store: store, reader: reader, snapshot: snapshot)

        _ = try await service.synchronizeNow()

        #expect(await snapshot.getSnapshotMetadata()?.lastForceScanDate == nil)
    }

    @Test("Scoped observation removes only canonical rows inside its scope")
    func limitsRemovalsToScope() async throws {
        let target = mirrorTrack(id: "A", artist: "Target")
        let outside = mirrorTrack(id: "B", artist: "Other")
        let store = ObservationMirrorStore(stored: [outside, target])
        let reader = try ObservationReader(templates: [template(
            currentIDs: [],
            rows: [],
            metadataRequestedIDs: [],
            membership: .scoped(unobservedIDs: [])
        )])
        let service = makeService(
            store: store,
            reader: reader,
            testArtists: ["Target"]
        )

        let result = try await service.synchronizeNow()

        #expect(result.removedTrackIDs == ["A"])
        #expect(await store.stored.map(\.id) == ["B"])
    }

    @Test("Stable empty observation removes a full canonical mirror")
    func acceptsStableEmptyObservation() async throws {
        let store = ObservationMirrorStore(stored: [mirrorTrack(id: "B"), mirrorTrack(id: "A")])
        let reader = try ObservationReader(templates: [template(
            currentIDs: [],
            rows: [],
            metadataRequestedIDs: []
        )])
        let service = makeService(store: store, reader: reader)

        let result = try await service.synchronizeNow()

        #expect(result.removedTrackIDs == ["A", "B"])
        #expect(await store.stored.isEmpty)
        #expect(await store.applyCalls.count == 1)
    }

    @Test("Observation failure is not converted into stable empty membership")
    func preservesObservationFailure() async throws {
        let store = ObservationMirrorStore(stored: [mirrorTrack(id: "A")])
        let reader = ObservationReader(error: .readFailed)
        let service = makeService(store: store, reader: reader)

        await #expect(throws: SyncObservationTestError.readFailed) {
            _ = try await service.synchronizeNow()
        }
        #expect(await store.applyCalls.isEmpty)
        #expect(await store.stored.map(\.id) == ["A"])
    }

    @Test("Duplicate authoritative metadata fails before mirror mutation")
    func rejectsDuplicateMetadata() async throws {
        let databaseID = try databaseID("A")
        let generation = try #require(LibraryGeneration(sourceValue: "duplicate-generation"))
        let stored = mirrorTrack(id: "A", genre: "Metal")
        let source = try DuplicateMetadataSource(
            census: TrackIDCensus(ids: [databaseID], totalCount: 1, generation: generation),
            metadata: [stored, stored]
        )
        let observer = MusicAppObserver(source: source)
        let store = ObservationMirrorStore(stored: [stored])
        let service = LibrarySyncService(trackStore: store, observer: observer)

        do {
            _ = try await service.synchronizeNow(forceMetadataRefresh: true)
            Issue.record("Expected duplicate metadata to reject synchronization")
        } catch let MusicAppObservationError.duplicateMetadata(duplicateID) {
            #expect(duplicateID == databaseID)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await store.applyCalls.isEmpty)
        #expect(await store.stored == [stored])
    }

    @Test("Failed atomic commit has no cache or timestamp side effects")
    func failedCommitHasNoSideEffects() async throws {
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let cache = MockCacheService()
        let snapshot = SyncMockLibrarySnapshotService()
        await snapshot.setMetadata(cacheMetadata(lastForceScanDate: oldDate))
        await seedSyncCaches(cache, artist: "Artist", album: "Album")
        let store = ObservationMirrorStore(
            stored: [mirrorTrack(id: "A", genre: "Rock")],
            applyError: .commitFailed
        )
        let reader = try ObservationReader(templates: [template(
            currentIDs: ["A"],
            rows: [row(id: "A", values: RowValues(genre: .value("Metal")))],
            metadataRequestedIDs: ["A"]
        )])
        let service = makeService(
            store: store,
            reader: reader,
            cache: cache,
            snapshot: snapshot,
            currentDate: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        await #expect(throws: SyncObservationTestError.commitFailed) {
            _ = try await service.synchronizeNow(forceMetadataRefresh: true)
        }

        await expectSyncCachesPreserved(cache, artist: "Artist", album: "Album")
        #expect(await snapshot.getSnapshotMetadata()?.lastForceScanDate == oldDate)
        #expect(await !(snapshot.wasCleared()))
        #expect(await store.stored.first?.genre == "Rock")
    }

    @Test("Database verification uses membership-only observation and one atomic deletion")
    func verifiesMembershipAtomically() async throws {
        let store = ObservationMirrorStore(stored: [mirrorTrack(id: "B"), mirrorTrack(id: "A")])
        let reader = try ObservationReader(templates: [template(
            currentIDs: ["A"],
            rows: [],
            metadataRequestedIDs: []
        )])
        let service = makeService(store: store, reader: reader)

        let result = try await service.verifyAndCleanDatabase(force: true)

        let request = try #require(await reader.requests.first)
        #expect(request.refresh == .membershipOnly)
        #expect(result.verifiedTrackCount == 2)
        #expect(result.removedTrackIDs == ["B"])
        let call = try #require(await store.applyCalls.first)
        #expect(call.upserting.isEmpty)
        #expect(call.deleting.map(\.rawValue) == ["B"])
    }

    @Test("Scoped verification ignores noncanonical rows outside its scope")
    func scopedVerificationIgnoresOutsideLegacyRows() async throws {
        let target = mirrorTrack(id: "A", artist: "Target")
        let outside = Track(
            id: "MUSIC-KIT-B",
            name: "Outside",
            artist: "Other",
            album: "Album",
            appleScriptID: "DATABASE-B"
        )
        let store = ObservationMirrorStore(stored: [target, outside])
        let reader = try ObservationReader(templates: [template(
            currentIDs: [],
            rows: [],
            metadataRequestedIDs: [],
            membership: .scoped(unobservedIDs: [])
        )])
        let service = makeService(store: store, reader: reader, testArtists: ["Target"])

        let result = try await service.verifyAndCleanDatabase(force: true)

        #expect(result.removedTrackIDs == ["A"])
        #expect(await store.stored.map(\.id) == ["MUSIC-KIT-B"])
    }

    @Test("Failed verification observation has no atomic commit")
    func failedVerificationHasNoCommit() async throws {
        let store = ObservationMirrorStore(stored: [mirrorTrack(id: "A")])
        let reader = ObservationReader(error: .readFailed)
        let service = makeService(store: store, reader: reader)

        await #expect(throws: SyncObservationTestError.readFailed) {
            _ = try await service.verifyAndCleanDatabase(force: true)
        }

        #expect(await store.applyCalls.isEmpty)
        #expect(await store.stored.map(\.id) == ["A"])
    }

    private func makeService(
        store: ObservationMirrorStore,
        reader: ObservationReader,
        cache: MockCacheService? = nil,
        snapshot: SyncMockLibrarySnapshotService? = nil,
        testArtists: [String] = [],
        currentDate: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) }
    ) -> LibrarySyncService {
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibrarySyncObservationTests-\(UUID().uuidString)")
        return LibrarySyncService(
            trackStore: store,
            cache: cache,
            librarySnapshotService: snapshot,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(
                logsBaseDirectory: logDirectory.path,
                lastDatabaseVerifyLog: "last.log",
                testArtists: testArtists
            ),
            currentDate: currentDate,
            observer: reader
        )
    }

    private func template(
        currentIDs: [String],
        rows: [LibraryTrackRow],
        metadataRequestedIDs: [String],
        metadataObservedIDs: [String]? = nil,
        membership: MembershipCompleteness = .full
    ) throws -> ObservationTemplate {
        try ObservationTemplate(
            rows: rows,
            censusIDs: databaseIDs(currentIDs),
            currentIDs: databaseIDs(currentIDs),
            membership: membership,
            requestedIDs: databaseIDs(metadataRequestedIDs),
            observedIDs: databaseIDs(metadataObservedIDs ?? rows.map(\.databaseID.rawValue)),
            generation: #require(LibraryGeneration(sourceValue: "G1"))
        )
    }

    private func row(id: String, values: RowValues = .init()) throws -> LibraryTrackRow {
        try LibraryTrackRow(
            databaseID: databaseID(id),
            metadata: LibraryTrackMetadata(
                text: LibraryTrackText(
                    name: values.name,
                    artist: values.artist,
                    album: values.album,
                    albumArtist: values.albumArtist
                ),
                genre: values.genre,
                editableYear: values.year,
                releaseYear: values.releaseYear,
                dateAdded: .absent,
                lastModified: values.lastModified,
                status: .absent
            )
        )
    }

    private func databaseIDs(_ values: [String]) throws -> Set<MusicDatabaseTrackID> {
        try Set(values.map(databaseID))
    }

    private func databaseID(_ value: String) throws -> MusicDatabaseTrackID {
        try #require(MusicDatabaseTrackID(rawValue: value))
    }

    private func mirrorTrack(
        id: String,
        artist: String = "Artist",
        genre: String? = nil,
        year: Int? = nil,
        albumArtist: String? = nil,
        lastModified: Date? = nil
    ) -> Track {
        Track(
            id: id,
            name: "Song",
            artist: artist,
            album: "Album",
            genre: genre,
            year: year,
            lastModified: lastModified,
            originalArtist: "Original Artist",
            yearBeforeMGU: 1999,
            yearSetByMGU: 2000,
            albumArtist: albumArtist,
            appleScriptID: id
        )
    }

    private func cacheMetadata(lastForceScanDate: Date) -> LibraryCacheMetadata {
        LibraryCacheMetadata(
            trackCount: 1,
            snapshotHash: "hash",
            timestamp: lastForceScanDate,
            libraryModificationDate: lastForceScanDate,
            lastForceScanDate: lastForceScanDate
        )
    }
}

private struct ObservationTemplate: Sendable {
    let rows: [LibraryTrackRow]
    let censusIDs: Set<MusicDatabaseTrackID>
    let currentIDs: Set<MusicDatabaseTrackID>
    let membership: MembershipCompleteness
    let requestedIDs: Set<MusicDatabaseTrackID>
    let observedIDs: Set<MusicDatabaseTrackID>
    let generation: LibraryGeneration
}

private enum SyncObservationTestError: Error, Equatable {
    case readFailed
    case commitFailed
}

private actor DuplicateMetadataSource: ObservationSource {
    private let census: TrackIDCensus
    private let metadata: [Track]

    init(census: TrackIDCensus, metadata: [Track]) {
        self.census = census
        self.metadata = metadata
    }

    func fetchCensus() -> TrackIDCensus {
        census
    }

    func fetchMetadata(for _: [MusicDatabaseTrackID]) -> [Track] {
        metadata
    }
}

private actor ObservationReader: MusicAppReading {
    private var templates: [ObservationTemplate]
    private let error: SyncObservationTestError?
    private(set) var requests: [LibraryObservationRequest] = []

    init(
        templates: [ObservationTemplate] = [],
        error: SyncObservationTestError? = nil
    ) {
        self.templates = templates
        self.error = error
    }

    func observe(_ request: LibraryObservationRequest) throws -> LibraryObservation {
        requests.append(request)
        if let error {
            throw error
        }
        let template = templates.count == 1 ? templates[0] : templates.removeFirst()
        return LibraryObservation(
            tracks: template.rows,
            censusIDs: template.censusIDs,
            currentIDs: template.currentIDs,
            scope: request.scope,
            observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            membership: template.membership,
            metadata: MetadataCompleteness(
                requestedIDs: template.requestedIDs,
                observedIDs: template.observedIDs
            ),
            generation: template.generation,
            issues: []
        )
    }
}

private actor ObservationMirrorStore: TrackStateStore {
    struct ApplyCall: Sendable {
        let upserting: [Track]
        let deleting: [MusicDatabaseTrackID]
    }

    private(set) var stored: [Track]
    private(set) var applyCalls: [ApplyCall] = []
    private let applyError: SyncObservationTestError?
    private var revision = MirrorRevision.initial

    init(
        stored: [Track],
        applyError: SyncObservationTestError? = nil
    ) {
        self.stored = stored
        self.applyError = applyError
    }

    func initialize() async throws {
        // The test provides initialized mirror state and does not exercise initialization persistence.
    }

    func loadAllTracks() async throws -> [Track] {
        stored
    }

    func loadMirrorSnapshot() async throws -> TrackMirrorSnapshot {
        TrackMirrorSnapshot(revision: revision, tracks: stored, coverage: .verified(.fullLibrary))
    }

    @discardableResult
    func applyMirror(_ update: TrackMirrorUpdate) async throws -> MirrorRevision {
        applyCalls.append(ApplyCall(upserting: update.upserts, deleting: update.deletions))
        if let applyError {
            throw applyError
        }
        guard update.baseRevision == revision else {
            throw MirrorRevisionConflict(expected: update.baseRevision, actual: revision)
        }
        let nextRevision = try revision.advanced()

        let deletedValues = Set(update.deletions.map(\.rawValue))
        stored.removeAll { deletedValues.contains($0.id) }
        for track in update.upserts {
            if let index = stored.firstIndex(where: { $0.id == track.id }) {
                stored[index] = track
            } else {
                stored.append(track)
            }
        }
        stored.sort { $0.id < $1.id }
        revision = nextRevision
        return revision
    }

    func getTrack(byID id: String) async throws -> Track? {
        stored.first { $0.id == id }
    }

    func persistAppliedChange(_: ChangeLogEntry) async throws {
        // The test exercises mirror reconciliation, not change-log persistence.
    }

    func getUnprocessedTracks() async throws -> [Track] {
        stored
    }

    func trackCount() async throws -> Int {
        stored.count
    }
}
