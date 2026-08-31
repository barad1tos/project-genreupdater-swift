import Foundation
import SwiftData
import Testing
@testable import Core
@testable import Services

@Suite("Library sync attempt state")
struct LibrarySyncStateTests {
    @Test("Runtime configuration is immutable after an attempt starts")
    func freezesConfiguration() async throws {
        let gate = SyncStateGate()
        let store = SyncStateStore(loadGate: gate)
        let reader = SyncMockScriptClient()
        let track = Track(id: "1", name: "Only", artist: "Original", album: "Album")
        await reader.setLibrary(ids: ["1"], tracks: ["1": track])
        let service = LibrarySyncService(
            trackStore: store,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(testArtists: ["Original"]),
            observer: reader
        )

        let synchronization = Task { try await service.synchronizeNow() }
        await gate.waitUntilEntered()
        await service.updateRuntimeConfiguration(
            LibrarySyncRuntimeConfiguration(testArtists: ["Replacement"])
        )
        await gate.open()
        _ = try await synchronization.value

        let request = try #require(await reader.recordedObservationRequests().first)
        #expect(request.scope.normalizedTestArtists == ["Original"])
    }

    @Test("Cancellation after observation starts prevents the commit")
    func cancellationStopsCommit() async throws {
        let gate = SyncStateGate()
        let store = SyncStateStore()
        let reader = GatedSyncReader(gate: gate)
        let service = LibrarySyncService(trackStore: store, observer: reader)

        let synchronization = Task { try await service.synchronizeNow() }
        await gate.waitUntilEntered()
        synchronization.cancel()
        await gate.open()

        do {
            _ = try await synchronization.value
            Issue.record("A cancelled observation reached the mirror commit")
        } catch is CancellationError {
            // Expected: cancellation is checked before the first durable mutation.
        }
        #expect(await store.commitCount == 0)
    }

    @Test("Cancellation while loading the mirror prevents source observation")
    func cancellationStopsAfterMirrorLoad() async throws {
        let gate = SyncStateGate()
        let store = SyncStateStore(loadGate: gate)
        let reader = SyncMockScriptClient()
        let service = LibrarySyncService(trackStore: store, observer: reader)

        let synchronization = Task { try await service.synchronizeNow() }
        await gate.waitUntilEntered()
        synchronization.cancel()
        await gate.open()

        await #expect(throws: CancellationError.self) {
            try await synchronization.value
        }
        #expect(await reader.recordedObservationRequests().isEmpty)
        #expect(await store.commitCount == 0)
    }

    @Test("Cancellation before conflict backoff prevents a retry")
    func cancellationBeforeConflictRetry() async throws {
        let gate = SyncStateGate()
        let store = SyncStateStore()
        let delegate = SyncMockScriptClient()
        let reader = TransientConflictReader(delegate: delegate, firstAttemptGate: gate)
        let service = LibrarySyncService(
            trackStore: store,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(
                mirrorRetryPolicy: MirrorRetryPolicy(retryLimit: 1, delay: .seconds(60))
            ),
            observer: reader
        )

        let synchronization = Task { try await service.synchronizeNow() }
        await gate.waitUntilEntered()
        synchronization.cancel()
        await gate.open()

        await #expect(throws: CancellationError.self) {
            try await synchronization.value
        }
        #expect(await reader.attemptCount == 1)
        #expect(await store.commitCount == 0)
    }

    @Test("The public result uses values accepted by the mirror store")
    func returnsCommittedValues() async throws {
        let store = SyncStateStore(normalizedName: "Normalized")
        let reader = SyncMockScriptClient()
        let track = Track(id: "1", name: "Observed", artist: "Artist", album: "Album")
        await reader.setLibrary(ids: ["1"], tracks: ["1": track])
        let service = LibrarySyncService(trackStore: store, observer: reader)

        let result = try await service.synchronizeNow(forceMetadataRefresh: true)

        #expect(result.newTracks.map(\.name) == ["Normalized"])
        #expect(await store.storedTracks.map(\.name) == ["Normalized"])
    }

    @Test("The public result rejects accepted IDs missing from the committed snapshot")
    func rejectsMissingCommittedRows() async throws {
        let store = SyncStateStore(committedSnapshotFault: .omitsAcceptedTrack)
        let reader = SyncMockScriptClient()
        let track = Track(id: "1", name: "Observed", artist: "Artist", album: "Album")
        await reader.setLibrary(ids: ["1"], tracks: ["1": track])
        let snapshotService = SyncMockLibrarySnapshotService()
        let service = LibrarySyncService(
            trackStore: store,
            librarySnapshotService: snapshotService,
            observer: reader
        )

        await #expect(throws: LibrarySyncObservationError.self) {
            try await service.synchronizeNow(forceMetadataRefresh: true)
        }
        #expect(await !snapshotService.wasCleared())
    }

    @Test("The public result rejects removed IDs retained by the committed snapshot")
    func rejectsRetainedRemovedRows() async throws {
        let removed = Track(id: "2", name: "Removed", artist: "Artist", album: "Album", appleScriptID: "2")
        let store = SyncStateStore(
            initialTracks: [removed],
            committedSnapshotFault: .retainsRemovedTrack
        )
        let reader = SyncMockScriptClient()
        await reader.setLibrary(ids: [], tracks: [:])
        let snapshotService = SyncMockLibrarySnapshotService()
        let service = LibrarySyncService(
            trackStore: store,
            librarySnapshotService: snapshotService,
            observer: reader
        )

        await #expect(throws: LibrarySyncObservationError.self) {
            try await service.synchronizeNow(forceMetadataRefresh: true)
        }
        #expect(await !snapshotService.wasCleared())
    }

    @Test("The public result rejects a committed snapshot with another revision")
    func rejectsRevisionMismatch() async throws {
        let store = SyncStateStore(committedSnapshotFault: .mismatchedRevision)
        let reader = SyncMockScriptClient()
        let track = Track(id: "1", name: "Observed", artist: "Artist", album: "Album")
        await reader.setLibrary(ids: ["1"], tracks: ["1": track])
        let snapshotService = SyncMockLibrarySnapshotService()
        let service = LibrarySyncService(
            trackStore: store,
            librarySnapshotService: snapshotService,
            observer: reader
        )

        await #expect(throws: LibrarySyncObservationError.self) {
            try await service.synchronizeNow(forceMetadataRefresh: true)
        }
        #expect(await !snapshotService.wasCleared())
    }

    @Test("The public result rejects missing committed certificate evidence")
    func rejectsMissingCertificate() async throws {
        let store = SyncStateStore(committedSnapshotFault: .omitsCertificate)
        let reader = SyncMockScriptClient()
        let track = Track(id: "1", name: "Observed", artist: "Artist", album: "Album")
        await reader.setLibrary(ids: ["1"], tracks: ["1": track])
        let snapshotService = SyncMockLibrarySnapshotService()
        let service = LibrarySyncService(
            trackStore: store,
            librarySnapshotService: snapshotService,
            observer: reader
        )

        await #expect(throws: LibrarySyncObservationError.self) {
            try await service.synchronizeNow(forceMetadataRefresh: true)
        }
        #expect(await !snapshotService.wasCleared())
    }

    @Test("A successful commit binds scope evidence and one audit record")
    func storesCommittedEvidence() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = TrackDataStore(modelContainer: container)
        try await store.initialize()
        let reader = SyncMockScriptClient(observedAt: { Date(timeIntervalSince1970: 1_800_000_010) })
        let track = Track(id: "1", name: "Track", artist: "Artist", album: "Album")
        await reader.setLibrary(ids: ["1"], tracks: ["1": track])
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let service = LibrarySyncService(
            trackStore: store,
            currentDate: { startedAt },
            observer: reader
        )

        let result = try await service.synchronizeNow(forceMetadataRefresh: true)
        let scope = try #require(result.scope)
        let context = ModelContext(container)
        let record = try #require(context.fetch(FetchDescriptor<PersistedSyncRecord>()).first)

        #expect(scope.mirrorRevision == MirrorRevision(value: 1))
        #expect(scope.certificateID == record.certificateID)
        #expect(record.baseRevisionValue == 0)
        #expect(record.committedRevisionValue == 1)
        #expect(record.scopeID == scope.id)
        #expect(record.modeRaw == "force")
        #expect(record.newCount == 1)
        #expect(record.identityRequestedCount == 1)
        #expect(record.identityObservedCount == 1)
        #expect(record.metadataRequestedCount == 1)
        #expect(record.metadataObservedCount == 1)
        #expect(record.outcomeRaw == "committed")
    }

    @Test("A transient source-generation conflict restarts the whole observation")
    func retriesSourceGenerationConflict() async throws {
        let store = SyncStateStore()
        let delegate = SyncMockScriptClient()
        let track = Track(id: "1", name: "Track", artist: "Artist", album: "Album")
        await delegate.setLibrary(ids: ["1"], tracks: ["1": track])
        let reader = TransientConflictReader(delegate: delegate)
        let service = LibrarySyncService(
            trackStore: store,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(
                mirrorRetryPolicy: MirrorRetryPolicy(retryLimit: 1, delay: .zero)
            ),
            observer: reader
        )

        let result = try await service.synchronizeNow()

        #expect(await reader.attemptCount == 2)
        #expect(await store.commitCount == 1)
        #expect(result.newTracks.map(\.id) == ["1"])
    }

    @Test("A changed bulk snapshot restarts the whole observation")
    func retriesBulkSnapshotChange() async throws {
        let store = SyncStateStore()
        let delegate = SyncMockScriptClient()
        let track = Track(id: "1", name: "Track", artist: "Artist", album: "Album")
        await delegate.setLibrary(ids: ["1"], tracks: ["1": track])
        let reader = TransientConflictReader(delegate: delegate, conflict: .snapshotChanged)
        let service = LibrarySyncService(
            trackStore: store,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(
                mirrorRetryPolicy: MirrorRetryPolicy(retryLimit: 1, delay: .zero)
            ),
            observer: reader
        )

        let result = try await service.synchronizeNow()

        #expect(await reader.attemptCount == 2)
        #expect(await store.commitCount == 1)
        #expect(result.newTracks.map(\.id) == ["1"])
    }

    @Test("A verified write fences an in-flight synchronization")
    func appliedWriteFencesSynchronization() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = TrackDataStore(modelContainer: container)
        try await store.initialize()
        let original = Track(id: "1", name: "Track", artist: "Artist", album: "Album", year: 2001)
        try await store.seedMirror([original])

        let gate = SyncStateGate()
        let delegate = SyncMockScriptClient()
        await delegate.setLibrary(ids: ["1"], tracks: ["1": original])
        let reader = WriteRaceReader(gate: gate, delegate: delegate)
        let service = LibrarySyncService(
            trackStore: store,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(
                mirrorRetryPolicy: MirrorRetryPolicy(retryLimit: 1, delay: .zero)
            ),
            observer: reader
        )

        let synchronization = Task { try await service.synchronizeNow(forceMetadataRefresh: true) }
        await gate.waitUntilEntered()

        var change = ChangeLogEntry(
            changeType: .yearUpdate,
            trackID: "1",
            artist: "Artist",
            trackName: "Track",
            albumName: "Album"
        )
        change.oldYear = 2001
        change.newYear = 2002
        try await store.commitAppliedChange(change)
        let writeSnapshot = try await store.loadMirrorSnapshot()

        var written = original
        written.year = 2002
        await delegate.setLibrary(ids: ["1"], tracks: ["1": written])
        await gate.open()
        _ = try await synchronization.value

        let finalSnapshot = try await store.loadMirrorSnapshot()
        #expect(writeSnapshot.revision == MirrorRevision(value: 2))
        #expect(await reader.attemptCount == 2)
        #expect(finalSnapshot.presentTracks.first?.year == 2002)
    }
}

private actor SyncStateGate {
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasEntered = false
    private var isOpen = false

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func wait() async {
        hasEntered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor GatedSyncReader: MusicAppReading {
    private let gate: SyncStateGate

    init(gate: SyncStateGate) {
        self.gate = gate
    }

    func observe(_ request: LibraryObservationRequest) async throws -> LibraryObservation {
        await gate.wait()
        let databaseID = try #require(MusicDatabaseTrackID(rawValue: "1"))
        let generation = try #require(LibraryGeneration(sourceValue: "state-test"))
        let row = LibraryTrackRow(
            databaseID: databaseID,
            metadata: LibraryTrackMetadata(
                text: LibraryTrackText(
                    name: .value("Track"),
                    artist: .value("Artist"),
                    album: .value("Album"),
                    albumArtist: .absent
                ),
                genre: .absent,
                editableYear: .absent,
                releaseYear: .absent,
                dateAdded: .absent,
                lastModified: .absent,
                status: .absent
            )
        )
        return LibraryObservation(
            tracks: [row],
            identities: [row.identityRow],
            epoch: LibraryObservationEpoch(
                censusIDs: [databaseID],
                currentIDs: [databaseID],
                scope: request.scope,
                observedAt: Date(timeIntervalSince1970: 1_800_000_000),
                generation: generation
            ),
            coverage: LibraryObservationCoverage(
                membership: .full,
                identity: IdentityCompleteness(
                    requestedIDs: [databaseID],
                    observedIDs: [databaseID]
                ),
                metadata: MetadataCompleteness(
                    requestedIDs: [databaseID],
                    observedIDs: [databaseID]
                ),
                issues: []
            )
        )
    }
}

private actor TransientConflictReader: MusicAppReading {
    enum Conflict {
        case censusChanged
        case snapshotChanged
    }

    private let delegate: SyncMockScriptClient
    private let firstAttemptGate: SyncStateGate?
    private let conflict: Conflict
    private(set) var attemptCount = 0

    init(
        delegate: SyncMockScriptClient,
        firstAttemptGate: SyncStateGate? = nil,
        conflict: Conflict = .censusChanged
    ) {
        self.delegate = delegate
        self.firstAttemptGate = firstAttemptGate
        self.conflict = conflict
    }

    func observe(_ request: LibraryObservationRequest) async throws -> LibraryObservation {
        attemptCount += 1
        if attemptCount == 1 {
            if let firstAttemptGate {
                await firstAttemptGate.wait()
            }
            switch conflict {
            case .censusChanged:
                throw MusicAppObservationError.censusChanged
            case .snapshotChanged:
                throw MusicAppObservationError.snapshotChanged(detail: "Bulk snapshot changed")
            }
        }
        return try await delegate.observe(request)
    }
}

private actor WriteRaceReader: MusicAppReading {
    private let gate: SyncStateGate
    private let delegate: SyncMockScriptClient
    private(set) var attemptCount = 0

    init(gate: SyncStateGate, delegate: SyncMockScriptClient) {
        self.gate = gate
        self.delegate = delegate
    }

    func observe(_ request: LibraryObservationRequest) async throws -> LibraryObservation {
        attemptCount += 1
        if attemptCount == 1 {
            await gate.wait()
        }
        return try await delegate.observe(request)
    }
}

private actor SyncStateStore: TrackStateStore {
    enum CommittedSnapshotFault: Equatable {
        case none
        case omitsAcceptedTrack
        case retainsRemovedTrack
        case mismatchedRevision
        case omitsCertificate
    }

    private let loadGate: SyncStateGate?
    private let normalizedName: String?
    private let committedSnapshotFault: CommittedSnapshotFault
    private var revision = MirrorRevision.initial
    private var presentIDs: Set<MusicDatabaseTrackID>
    private var certificates: [ScopeCertificate] = []
    private(set) var storedTracks: [Track]
    private(set) var commitCount = 0

    init(
        loadGate: SyncStateGate? = nil,
        normalizedName: String? = nil,
        initialTracks: [Track] = [],
        committedSnapshotFault: CommittedSnapshotFault = .none
    ) {
        self.loadGate = loadGate
        self.normalizedName = normalizedName
        self.committedSnapshotFault = committedSnapshotFault
        storedTracks = initialTracks
        presentIDs = Set(initialTracks.compactMap(\.databaseID))
    }

    func initialize() async throws {
        // This in-memory test store has no external resources to initialize.
    }

    func loadMirrorSnapshot() async throws -> TrackMirrorSnapshot {
        if let loadGate {
            await loadGate.wait()
        }
        return try mirrorSnapshot(
            revision: revision,
            tracks: storedTracks,
            presentIDs: presentIDs,
            certificates: certificates
        )
    }

    func commitMirror(_ commit: MirrorCommit) async throws -> MirrorCommitResult {
        guard commit.baseRevision == revision else {
            throw MirrorRevisionConflict(expected: commit.baseRevision, actual: revision)
        }
        let tracksBeforeCommit = storedTracks
        commitCount += 1
        if let ids = inventoryIDs(commit.inventoryChange) {
            presentIDs = Set(ids)
        }
        applyInventory(commit.inventoryChange, to: &storedTracks)
        for var track in commit.upserts {
            if let normalizedName {
                track.name = normalizedName
            }
            if let index = storedTracks.firstIndex(where: { $0.id == track.id }) {
                storedTracks[index] = track
            } else {
                storedTracks.append(track)
            }
        }
        switch commit.certificates {
        case .preserve:
            break
        case let .replace(certificate), let .rebase(certificate):
            certificates = [certificate]
        case .invalidate:
            certificates = []
        }
        revision = try revision.advanced()
        let snapshot = try makeCommittedSnapshot(
            baseRevision: commit.baseRevision,
            tracksBeforeCommit: tracksBeforeCommit
        )
        return MirrorCommitResult(revision: revision, snapshot: snapshot)
    }

    private func makeCommittedSnapshot(
        baseRevision: MirrorRevision,
        tracksBeforeCommit: [Track]
    ) throws -> TrackMirrorSnapshot {
        let snapshotRevision = committedSnapshotFault == .mismatchedRevision
            ? baseRevision
            : revision
        let snapshotTracks: [Track] = switch committedSnapshotFault {
        case .omitsAcceptedTrack:
            []
        case .retainsRemovedTrack:
            storedTracks + tracksBeforeCommit.filter { previous in
                !storedTracks.contains(where: { $0.id == previous.id })
            }
        case .none, .mismatchedRevision, .omitsCertificate:
            storedTracks
        }
        let snapshotCertificates = committedSnapshotFault == .omitsCertificate ? [] : certificates
        return try mirrorSnapshot(
            revision: snapshotRevision,
            tracks: snapshotTracks,
            presentIDs: presentIDs,
            certificates: snapshotCertificates
        )
    }

    func getTrack(byID id: String) async throws -> Track? {
        storedTracks.first { $0.id == id }
    }

    func commitAppliedChange(_: ChangeLogEntry) async throws -> MirrorRevision {
        // Synchronization tests do not exercise the independent change-log store.
        revision
    }
    func commitObservedChange(_ change: ChangeLogEntry) async throws -> MirrorRevision {
        try await commitAppliedChange(change)
    }
    func commitRevertedChange(
        _ change: ChangeLogEntry,
        removingHistoryEntryID _: UUID
    ) async throws -> MirrorRevision {
        try await commitAppliedChange(change)
    }

    func getUnprocessedTracks() async throws -> [Track] {
        storedTracks
    }

    func trackCount() async throws -> Int {
        storedTracks.count
    }
}
