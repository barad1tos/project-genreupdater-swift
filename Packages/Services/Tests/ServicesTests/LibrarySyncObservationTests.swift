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
        var dateAdded: Observed<Date> = .absent
        var lastModified: Observed<Date> = .absent
        var status: Observed<String> = .absent
    }

    enum ProcessingField: CaseIterable, Sendable {
        case name
        case artist
        case album
        case albumArtist
        case genre
        case editableYear
        case releaseYear
        case dateAdded
        case lastModified
        case status
    }

    @Test("A complete current observation replaces the exact scope certificate")
    func issuesExactCertificate() async throws {
        let store = ObservationMirrorStore(stored: [])
        let reader = try ObservationReader(templates: [template(
            currentIDs: ["A"],
            rows: [row(id: "A", values: RowValues(artist: .value("Metallica")))],
            metadataRequestedIDs: ["A"],
            membership: .scoped(unobservedIDs: [])
        )])
        let service = makeService(store: store, reader: reader, testArtists: [" Metallica "])

        let detection = try await service.detectObservation(forceMetadataRefresh: true)

        guard case let .replace(certificate) = detection.certificateChange else {
            Issue.record("Expected a replacement certificate")
            return
        }
        #expect(certificate.revision == MirrorRevision(value: 1))
        #expect(certificate.normalizedTestArtists == ["Metallica"])
        #expect(certificate.requestedFingerprint == certificate.observedFingerprint)
        #expect(certificate.trackCount == 1)
    }

    @Test("Incomplete requested IDs invalidate scope evidence")
    func invalidatesIncompleteObservation() async throws {
        let store = ObservationMirrorStore(stored: [mirrorTrack(id: "A")])
        let reader = try ObservationReader(templates: [template(
            currentIDs: ["A", "B"],
            rows: [row(id: "A")],
            metadataRequestedIDs: ["A", "B"],
            metadataObservedIDs: ["A"]
        )])
        let service = makeService(store: store, reader: reader)

        let detection = try await service.detectObservation(forceMetadataRefresh: true)

        #expect(detection.certificateChange == .invalidate(.incompleteObservation))
    }

    @Test(
        "Every unobserved processing field invalidates certification and force completion",
        arguments: ProcessingField.allCases
    )
    func rejectsUnobservedField(_ field: ProcessingField) async throws {
        let store = ObservationMirrorStore(stored: [mirrorTrack(id: "A", genre: "Metal")])
        let reader = try ObservationReader(templates: [template(
            currentIDs: ["A"],
            rows: [row(id: "A", values: values(unobserving: field))],
            metadataRequestedIDs: ["A"]
        )])
        let service = makeService(store: store, reader: reader)

        let detection = try await service.detectObservation(forceMetadataRefresh: true)

        #expect(detection.certificateChange == .invalidate(.incompleteObservation))
        #expect(!detection.didCompleteForceRefresh)
    }

    @Test("Either artist field defines the producer scope")
    func matchesEitherArtistField() async throws {
        let includedID = try databaseID("A")
        let excludedID = try databaseID("B")
        let generation = try #require(LibraryGeneration(sourceValue: "album-artist-precedence"))
        let census = try TrackIDCensus(ids: [includedID, excludedID], totalCount: 2, generation: generation)
        let source = StaticObservationSource(
            census: census,
            metadata: [
                mirrorTrack(id: "A", artist: "Other", albumArtist: "Target"),
                mirrorTrack(id: "B", artist: "Target", albumArtist: "Other"),
            ]
        )
        let store = ObservationMirrorStore(stored: [])
        let service = LibrarySyncService(
            trackStore: store,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(testArtists: ["Target"]),
            observer: MusicAppObserver(source: source)
        )

        let detection = try await service.detectObservation(forceMetadataRefresh: true)

        guard case let .replace(certificate) = detection.certificateChange else {
            Issue.record("Expected a replacement certificate")
            return
        }
        let includedFingerprint = try MembershipFingerprint.make(ids: [includedID, excludedID]).fingerprint
        #expect(certificate.trackCount == 2)
        #expect(certificate.observedFingerprint == includedFingerprint)
    }

    @Test("Album-targeted observations invalidate broader processing admission")
    func invalidatesAlbumTargetedObservation() async throws {
        let store = ObservationMirrorStore(stored: [mirrorTrack(id: "A")])
        let reader = try ObservationReader(templates: [template(
            currentIDs: ["A"],
            rows: [row(id: "A")],
            metadataRequestedIDs: ["A"]
        )])
        let service = makeService(
            store: store,
            reader: reader,
            albumTarget: AlbumIdentity(artist: "Artist", album: "Album")
        )

        let detection = try await service.detectObservation(forceMetadataRefresh: true)

        #expect(detection.certificateChange == .invalidate(.narrowedObservation))
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
        #expect(call.membershipIDs?.map(\.rawValue) == ["A", "B"])
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
        #expect(update.membershipIDs?.map(\.rawValue) == ["A"])
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
            detail: "metadata coverage does not match its request"
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

    @Test("Scoped observation uses the full census for canonical membership")
    func scopedObservationKeepsCensus() async throws {
        let target = mirrorTrack(id: "A", artist: "Target")
        let outside = mirrorTrack(id: "B", artist: "Other")
        let store = ObservationMirrorStore(stored: [outside, target])
        let reader = try ObservationReader(templates: [template(
            currentIDs: [],
            censusIDs: ["B"],
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

    @Test("Identical overlapping metadata rows collapse at the observation boundary")
    func collapsesIdenticalMetadata() async throws {
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

        let result = try await service.synchronizeNow(forceMetadataRefresh: true)

        #expect(!result.hasChanges)
        #expect(await store.stored == [stored])
    }

    @Test("Conflicting overlapping metadata rows fail before mirror mutation")
    func rejectsConflictingMetadata() async throws {
        let databaseID = try databaseID("A")
        let generation = try #require(LibraryGeneration(sourceValue: "conflicting-generation"))
        let stored = mirrorTrack(id: "A", genre: "Metal")
        let conflicting = mirrorTrack(id: "A", genre: "Rock")
        let source = try DuplicateMetadataSource(
            census: TrackIDCensus(ids: [databaseID], totalCount: 1, generation: generation),
            metadata: [stored, conflicting]
        )
        let observer = MusicAppObserver(source: source)
        let store = ObservationMirrorStore(stored: [stored])
        let service = LibrarySyncService(trackStore: store, observer: observer)

        do {
            _ = try await service.synchronizeNow(forceMetadataRefresh: true)
            Issue.record("Expected conflicting metadata to reject synchronization")
        } catch let MusicAppObservationError.conflictingMetadata(conflictingID) {
            #expect(conflictingID == databaseID)
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

    @Test("Database verification uses one atomic membership transition")
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
        #expect(call.membershipIDs?.map(\.rawValue) == ["A"])
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

    @Test("Scoped verification reports removals from the full library census")
    func reportsEveryRemoval() async throws {
        let target = mirrorTrack(id: "A", artist: "Target")
        let removedOutsideScope = mirrorTrack(id: "B", artist: "Other")
        let store = ObservationMirrorStore(stored: [target, removedOutsideScope])
        let reader = try ObservationReader(templates: [template(
            currentIDs: ["A"],
            censusIDs: ["A"],
            rows: [],
            metadataRequestedIDs: [],
            membership: .scoped(unobservedIDs: [])
        )])
        let service = makeService(store: store, reader: reader, testArtists: ["Target"])

        let result = try await service.verifyAndCleanDatabase(force: true)

        #expect(result.verifiedTrackCount == 1)
        #expect(result.removedTrackIDs == ["B"])
        #expect(await store.stored.map(\.id) == ["A"])
    }

    @Test("Scoped verification still applies an empty full-library census")
    func emptyScopeAppliesCensus() async throws {
        let outsideScope = mirrorTrack(id: "B", artist: "Other")
        let store = ObservationMirrorStore(stored: [outsideScope])
        let reader = try ObservationReader(templates: [template(
            currentIDs: [],
            censusIDs: [],
            rows: [],
            metadataRequestedIDs: [],
            membership: .scoped(unobservedIDs: [])
        )])
        let service = makeService(store: store, reader: reader, testArtists: ["Target"])

        let result = try await service.verifyAndCleanDatabase(force: true)

        #expect(result.verifiedTrackCount == 0)
        #expect(result.removedTrackIDs == ["B"])
        #expect(await store.stored.isEmpty)
    }

    @Test("Verification removes present membership without a metadata row")
    func metadataGapAppliesCensus() async throws {
        let missingID = try #require(MusicDatabaseTrackID(rawValue: "GAP"))
        let store = ObservationMirrorStore(stored: [], presentIDs: [missingID])
        let reader = try ObservationReader(templates: [template(
            currentIDs: [],
            censusIDs: [],
            rows: [],
            metadataRequestedIDs: [],
            membership: .full
        )])
        let service = makeService(store: store, reader: reader)

        let result = try await service.verifyAndCleanDatabase(force: true)

        #expect(result.verifiedTrackCount == 0)
        #expect(result.removedTrackIDs == ["GAP"])
        #expect(await store.presentIDs.isEmpty)
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
        snapshot: SyncMockLibrarySnapshotService? = nil,
        testArtists: [String] = [],
        albumTarget: AlbumIdentity? = nil,
        currentDate: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) }
    ) -> LibrarySyncService {
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibrarySyncObservationTests-\(UUID().uuidString)")
        return LibrarySyncService(
            trackStore: store,
            librarySnapshotService: snapshot,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(
                logsBaseDirectory: logDirectory.path,
                lastDatabaseVerifyLog: "last.log",
                testArtists: testArtists,
                albumTargetIdentity: albumTarget
            ),
            currentDate: currentDate,
            observer: reader
        )
    }

    private func template(
        currentIDs: [String],
        censusIDs: [String]? = nil,
        rows: [LibraryTrackRow],
        metadataRequestedIDs: [String],
        metadataObservedIDs: [String]? = nil,
        membership: MembershipCompleteness = .full
    ) throws -> ObservationTemplate {
        try ObservationTemplate(
            rows: rows,
            censusIDs: databaseIDs(censusIDs ?? currentIDs),
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
                dateAdded: values.dateAdded,
                lastModified: values.lastModified,
                status: values.status
            )
        )
    }

    private func values(unobserving field: ProcessingField) -> RowValues {
        var values = RowValues()
        let omitted = "omitted"
        switch field {
        case .name:
            values.name = .unobserved(reason: omitted)
        case .artist:
            values.artist = .unobserved(reason: omitted)
        case .album:
            values.album = .unobserved(reason: omitted)
        case .albumArtist:
            values.albumArtist = .unobserved(reason: omitted)
        case .genre:
            values.genre = .unobserved(reason: omitted)
        case .editableYear:
            values.year = .unobserved(reason: omitted)
        case .releaseYear:
            values.releaseYear = .unobserved(reason: omitted)
        case .dateAdded:
            values.dateAdded = .unobserved(reason: omitted)
        case .lastModified:
            values.lastModified = .unobserved(reason: omitted)
        case .status:
            values.status = .unobserved(reason: omitted)
        }
        return values
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
