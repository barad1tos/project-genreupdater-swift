import Core
import Foundation
import Testing
@testable import Services

@Suite("Write outcome safety")
struct WriteOutcomeTests {
    @Test("Single write preserves an unknown outcome")
    func preservesSingleOutcome() async {
        let track = makeTrack(id: "T1")
        let client = OutcomeScriptClient(tracks: [track])
        let cache = MockCacheService()
        let snapshot = MockLibrarySnapshotService()
        await cache.storeAlbumYear(artist: track.artist, album: track.album, year: 2000, confidence: 80)
        let coordinator = makeCoordinator(client, cache: cache, snapshot: snapshot)

        await #expect(throws: AppleScriptOutcomeError.self) {
            _ = try await coordinator.applyChange(makeGenreChange(track), isReviewedChange: false)
        }
        #expect(await cache.getAlbumYear(artist: track.artist, album: track.album) == nil)
        #expect(await snapshot.wasCleared())
    }

    @Test("Reviewed writes stop after an unknown outcome")
    func stopsReviewedWrites() async {
        let track = makeTrack(id: "T1")
        let client = OutcomeScriptClient(tracks: [track])
        let coordinator = makeCoordinator(client)
        var failedTrackIDs: [String] = []
        var errorDescriptions: [String] = []

        await #expect(throws: AppleScriptOutcomeError.self) {
            _ = try await coordinator.applyReviewedChangeGroup(
                [makeGenreChange(track), makeYearChange(track)],
                failedTrackIDs: &failedTrackIDs,
                errorDescriptions: &errorDescriptions
            )
        }
        #expect(await client.writeAttempts == 1)
    }

    @Test("Generated track updates stop after an unknown outcome")
    func stopsGeneratedUpdates() async {
        let tracks = [
            makeTrack(id: "T1", name: "First", year: 1969),
            makeTrack(id: "T2", name: "Second", year: 1969)
        ]
        let client = OutcomeScriptClient(tracks: tracks)
        let coordinator = makeCoordinator(client, year: 2020)

        await #expect(throws: AppleScriptOutcomeError.self) {
            _ = try await coordinator.updateTracks(
                tracks,
                options: UpdateOptions(updateGenre: false, updateYear: true),
                progressHandler: { _ in
                    // Progress delivery is unrelated to write-outcome propagation.
                }
            )
        }
        #expect(await client.writeAttempts == 1)
    }

    @Test("Pending verification stops after an unknown outcome")
    func stopsPendingVerification() async {
        let tracks = [makeTrack(id: "T1", year: 1969), makeTrack(id: "T2", year: 1969)]
        let client = OutcomeScriptClient(tracks: tracks)
        let coordinator = makeCoordinator(client, year: 2020)
        let pending = PendingAlbumEntry(
            id: "artist-album",
            artist: "Artist",
            album: "Album",
            reason: "no_year_found"
        )

        await #expect(throws: AppleScriptOutcomeError.self) {
            _ = try await coordinator.verifyPendingAlbum(pending, albumTracks: tracks)
        }
        #expect(await client.writeAttempts == 1)
    }

    @Test("Release-year restore stops after an unknown outcome")
    func stopsReleaseYearRestore() async {
        let tracks = [
            makeTrack(id: "T1", releaseYear: 1984),
            makeTrack(id: "T2", releaseYear: 1984)
        ]
        let client = OutcomeScriptClient(tracks: tracks)
        let coordinator = makeCoordinator(client)
        let progress = ProgressRecorder()

        await #expect(throws: AppleScriptOutcomeError.self) {
            _ = try await coordinator.restoreReleaseYears(
                in: tracks,
                threshold: 5,
                progressHandler: { update in
                    progress.append(update)
                }
            )
        }

        #expect(await client.writeAttempts == 1)
        #expect(!progress.values.contains { $0.phase == .complete })
    }

    @Test("Batch undo stops after an unknown outcome")
    func stopsBatchUndo() async {
        let client = OutcomeScriptClient(tracks: [])
        let cache = MockCacheService()
        let snapshot = MockUndoLibrarySnapshotService()
        await cache.storeAlbumYear(artist: "Artist", album: "Album", year: 2000, confidence: 80)
        let coordinator = makeUndoCoordinator(client, cache: cache, snapshot: snapshot)

        await #expect(throws: AppleScriptOutcomeError.self) {
            try await coordinator.revertBatch([
                makeYearEntry(id: "T1", oldYear: 1984),
                makeYearEntry(id: "T2", oldYear: 1985)
            ])
        }
        #expect(await client.writeAttempts == 1)
        #expect(await cache.getAlbumYear(artist: "Artist", album: "Album") == nil)
        #expect(await snapshot.wasCleared())
    }

    @Test("Batch undo stops after cancellation")
    func cancellationStopsBatchUndo() async {
        let client = OutcomeScriptClient(tracks: [], failure: .cancellation)
        let coordinator = makeUndoCoordinator(client)

        await #expect(throws: CancellationError.self) {
            try await coordinator.revertBatch([
                makeYearEntry(id: "T1", oldYear: 1984),
                makeYearEntry(id: "T2", oldYear: 1985)
            ])
        }
        #expect(await client.writeAttempts == 1)
    }

    @Test("CSV restore stops after an unknown outcome")
    func stopsCSVRestore() async {
        let tracks = [makeTrack(id: "T1", name: "First"), makeTrack(id: "T2", name: "Second")]
        let client = OutcomeScriptClient(tracks: tracks)
        let coordinator = makeUndoCoordinator(client)
        let csv = "artist,name,album,id,year\nArtist,First,Album,T1,1984\nArtist,Second,Album,T2,1985"

        await #expect(throws: AppleScriptOutcomeError.self) {
            _ = try await coordinator.revertYearsFromBackupCSV(
                csv,
                artist: "Artist",
                currentTracks: tracks
            )
        }
        #expect(await client.writeAttempts == 1)
    }

    @Test("Checkpoint failure stops the reviewed write loop")
    func stopsOnCheckpointFailure() async {
        let tracks = [
            makeTrack(id: "T1", name: "First", year: 1969),
            makeTrack(id: "T2", name: "Second", year: 1969)
        ]
        let client = MockAppleScriptClient()
        await client.setFetchedTracks(tracks)
        let coordinator = makeCoordinator(client)
        var failedTrackIDs: [String] = []
        var errorDescriptions: [String] = []

        await #expect(throws: WorkCheckpointError.self) {
            _ = try await coordinator.applyReviewedChangeGroup(
                [makeGenreChange(tracks[0]), makeGenreChange(tracks[1])],
                failedTrackIDs: &failedTrackIDs,
                errorDescriptions: &errorDescriptions,
                checkpoint: { _ in
                    throw WorkCheckpointError.persistence(.beforeAttempt, writeAdjacent: false)
                }
            )
        }
        #expect(await client.writtenProperties.isEmpty)
    }

    @Test("Finalization failure stops the reviewed write loop")
    func stopsOnFinalizationFailure() async {
        let tracks = [
            makeTrack(id: "T1", name: "First", year: 1969),
            makeTrack(id: "T2", name: "Second", year: 1969)
        ]
        let client = MockAppleScriptClient()
        await client.setFetchedTracks(tracks)
        let store = MockChangeLogStore()
        await store.failSaves()
        let coordinator = makeCoordinator(client, changeLogStore: store)
        var failedTrackIDs: [String] = []
        var errorDescriptions: [String] = []

        await #expect(throws: UpdateCoordinatorError.self) {
            _ = try await coordinator.applyReviewedChangeGroup(
                [makeGenreChange(tracks[0]), makeGenreChange(tracks[1])],
                failedTrackIDs: &failedTrackIDs,
                errorDescriptions: &errorDescriptions
            )
        }
        #expect(await client.writtenProperties.count == 1)
    }

    @Test("Batch finalization failure preserves verified outcomes")
    func batchFinalizationPreservesOutcomes() async {
        let tracks = [
            makeTrack(id: "T1", name: "First", year: 1969),
            makeTrack(id: "T2", name: "Second", year: 1969)
        ]
        let client = MockAppleScriptClient()
        await client.setFetchedTracks(tracks)
        let store = MockChangeLogStore()
        await store.failSaves()
        let coordinator = makeCoordinator(
            client,
            runtimeConfiguration: UpdateRuntimeConfiguration(
                areBatchUpdatesEnabled: true,
                maxBatchUpdateSize: 5
            ),
            changeLogStore: store
        )
        let checkpoints = CheckpointProbe()
        var failedTrackIDs: [String] = []
        var errorDescriptions: [String] = []
        let changes = [makeGenreChange(tracks[0]), makeGenreChange(tracks[1])]

        await #expect(throws: UpdateCoordinatorError.self) {
            _ = try await coordinator.applyReviewedChangeGroup(
                changes,
                failedTrackIDs: &failedTrackIDs,
                errorDescriptions: &errorDescriptions,
                checkpoint: { await checkpoints.append($0) }
            )
        }

        let verifications = await checkpoints.values.filter { $0.boundary == .afterVerification }
        #expect(verifications.count == 1)
        #expect(verifications.first?.states.count == changes.count)
    }

    @Test("CSV restore stops after cancellation")
    func cancellationStopsCSVRestore() async {
        let tracks = [makeTrack(id: "T1", name: "First"), makeTrack(id: "T2", name: "Second")]
        let client = OutcomeScriptClient(tracks: tracks, failure: .cancellation)
        let coordinator = makeUndoCoordinator(client)
        let csv = "artist,name,album,id,year\nArtist,First,Album,T1,1984\nArtist,Second,Album,T2,1985"

        await #expect(throws: CancellationError.self) {
            _ = try await coordinator.revertYearsFromBackupCSV(
                csv,
                artist: "Artist",
                currentTracks: tracks
            )
        }
        #expect(await client.writeAttempts == 1)
    }
}

// Safety: the lock protects every access to the progress snapshots.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ProgressUpdate] = []

    var values: [ProgressUpdate] {
        lock.withLock { items }
    }

    func append(_ update: ProgressUpdate) {
        lock.withLock { items.append(update) }
    }
}

actor OutcomeScriptClient: AppleScriptClient {
    enum Failure {
        case unknown
        case cancellation
        case plain
    }

    private let tracksByID: [String: Track]
    private let failure: Failure
    private let completion: ScriptCompletion?
    private(set) var writeAttempts = 0
    private(set) var batchAttempts = 0

    init(
        tracks: [Track],
        failure: Failure = .unknown,
        completion: ScriptCompletion? = nil
    ) {
        tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        self.failure = failure
        self.completion = completion
    }

    func initialize() async throws {
        // This in-memory client requires no setup.
    }

    func runScript(name _: String, arguments _: [String], timeout _: Duration?) async throws -> String? {
        nil
    }

    func fetchTracksByIDs(_ trackIDs: [String], batchSize _: Int, timeout _: Duration?) async throws -> [Track] {
        trackIDs.compactMap { tracksByID[$0] }
    }

    func fetchAllTrackIDs(timeout _: Duration?) async throws -> [String] {
        Array(tracksByID.keys)
    }

    func updateTrackProperty(trackID _: String, property _: String, value _: String) async throws
        -> AppleScriptWriteResult {
        writeAttempts += 1
        switch failure {
        case .unknown:
            throw unknownOutcome(scriptName: "update_property")
        case .cancellation:
            throw CancellationError()
        case .plain:
            throw PlainWriteError()
        }
    }

    func batchUpdateTracks(_: [TrackPropertyUpdate]) async throws {
        batchAttempts += 1
        switch failure {
        case .unknown:
            throw unknownOutcome(scriptName: "batch_update_tracks")
        case .cancellation:
            throw CancellationError()
        case .plain:
            throw PlainWriteError()
        }
    }

    private func unknownOutcome(scriptName: String) -> AppleScriptOutcomeError {
        guard let completion else {
            return AppleScriptOutcomeError(scriptName: scriptName, duration: .seconds(3))
        }
        return AppleScriptOutcomeError(
            scriptName: scriptName,
            duration: .seconds(3),
            completion: completion
        )
    }
}

private struct PlainWriteError: Error {}

func makeStoreFailure(itemIDs: [UUID]) throws -> CheckpointStoreFailure {
    let input = writeInput(workItems: itemIDs.map { makeWorkItem(id: $0, state: .prepared) })
    let initial = RunLifecycleSnapshot(
        request: .manualWrite(input: input),
        scope: input.scope,
        startedAt: Date(timeIntervalSince1970: 100),
        phase: .active(.writing)
    )
    let durable = try initial.applying(.beforeAttempt(itemIDs))
    let checkpoint = WorkCheckpoint.afterAttempt(itemIDs)
    return try CheckpointStoreFailure(
        checkpoint: checkpoint,
        candidate: durable.applying(checkpoint),
        durableSnapshot: durable,
        isWriteAdjacent: true,
        reason: "checkpoint store unavailable"
    )
}

func expectStoredCompletion(
    _ completion: ScriptCompletion,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected the checkpoint store failure")
    } catch let WorkCheckpointError.store(failure) {
        #expect(failure.completion === completion)
    } catch {
        Issue.record("Expected a checkpoint store failure, got \(type(of: error))")
    }
}

func makeCoordinator(
    _ client: any AppleScriptClient,
    year: Int? = nil,
    cache: any CacheService = MockCacheService(),
    snapshot: (any LibrarySnapshotService)? = nil,
    runtimeConfiguration: UpdateRuntimeConfiguration = UpdateRuntimeConfiguration(),
    changeLogStore: (any ChangeLogStore)? = nil
) -> UpdateCoordinator {
    let scores = year.map { [$0: 90] } ?? [:]
    let api = MockAPIService(yearResult: YearResult(year: year, confidence: 90, yearScores: scores))
    let undo = makeUndoCoordinator(client, cache: cache, snapshot: snapshot, changeLogStore: changeLogStore)
    return UpdateCoordinator(
        dependencies: UpdateDependencies(
            apiOrchestrator: makeAPIOrchestrator(
                musicBrainz: api,
                discogs: api,
                appleMusic: api
            ),
            scriptBridge: client,
            stores: .init(trackStore: MockTrackStore(), cache: cache),
            undoCoordinator: undo,
            librarySnapshotService: snapshot
        ),
        genreDeterminator: GenreDeterminator(),
        runtimeConfiguration: runtimeConfiguration
    )
}

private func makeUndoCoordinator(
    _ client: any AppleScriptClient,
    cache: (any CacheService)? = nil,
    snapshot: (any LibrarySnapshotService)? = nil,
    changeLogStore: (any ChangeLogStore)? = nil
) -> UndoCoordinator {
    UndoCoordinator(
        scriptBridge: client,
        stores: .init(changeLog: changeLogStore, cache: cache),
        librarySnapshotService: snapshot,
        directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("WriteOutcomeTests-\(UUID().uuidString)")
    )
}

func makeTrack(
    id: String,
    name: String = "Track",
    year: Int? = 2000,
    releaseYear: Int? = nil
) -> Track {
    Track(
        id: id,
        name: name,
        artist: "Artist",
        album: "Album",
        genre: "Rock",
        year: year,
        trackStatus: TrackKind.subscription.rawValue,
        releaseYear: releaseYear
    )
}

func makeGenreChange(_ track: Track) -> ProposedChange {
    ProposedChange(
        track: track,
        changeType: .genreUpdate,
        oldValue: "Rock",
        newValue: "Pop",
        confidence: 90,
        source: "test",
        isAccepted: true
    )
}

func makeYearChange(_ track: Track) -> ProposedChange {
    ProposedChange(
        track: track,
        changeType: .yearUpdate,
        oldValue: "2000",
        newValue: "2001",
        confidence: 90,
        source: "test",
        isAccepted: true
    )
}

private func makeYearEntry(id: String, oldYear: Int) -> ChangeLogEntry {
    var entry = ChangeLogEntry(
        changeType: .yearUpdate,
        trackID: id,
        artist: "Artist",
        trackName: "Track",
        albumName: "Album"
    )
    entry.oldYear = oldYear
    entry.newYear = 2000
    return entry
}
