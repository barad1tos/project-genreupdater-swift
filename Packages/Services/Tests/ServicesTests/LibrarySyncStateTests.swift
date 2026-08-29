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
    private let delegate: SyncMockScriptClient
    private(set) var attemptCount = 0

    init(delegate: SyncMockScriptClient) {
        self.delegate = delegate
    }

    func observe(_ request: LibraryObservationRequest) async throws -> LibraryObservation {
        attemptCount += 1
        if attemptCount == 1 {
            throw MusicAppObservationError.censusChanged
        }
        return try await delegate.observe(request)
    }
}

private actor SyncStateStore: TrackStateStore {
    private let loadGate: SyncStateGate?
    private let normalizedName: String?
    private var revision = MirrorRevision.initial
    private var presentIDs: Set<MusicDatabaseTrackID> = []
    private var certificates: [ScopeCertificate] = []
    private(set) var storedTracks: [Track] = []
    private(set) var commitCount = 0

    init(loadGate: SyncStateGate? = nil, normalizedName: String? = nil) {
        self.loadGate = loadGate
        self.normalizedName = normalizedName
    }

    func initialize() async throws {}

    func loadAllTracks() async throws -> [Track] {
        storedTracks
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
        return MirrorCommitResult(revision: revision)
    }

    func getTrack(byID id: String) async throws -> Track? {
        storedTracks.first { $0.id == id }
    }

    func persistAppliedChange(_: ChangeLogEntry) async throws {}

    func getUnprocessedTracks() async throws -> [Track] {
        storedTracks
    }

    func trackCount() async throws -> Int {
        storedTracks.count
    }
}
