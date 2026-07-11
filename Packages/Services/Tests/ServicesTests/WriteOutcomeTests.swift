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

private actor OutcomeScriptClient: AppleScriptClient {
    enum Failure {
        case unknown
        case cancellation
    }

    private let tracksByID: [String: Track]
    private let failure: Failure
    private(set) var writeAttempts = 0

    init(tracks: [Track], failure: Failure = .unknown) {
        tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        self.failure = failure
    }

    func initialize() async throws {}

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
            throw AppleScriptOutcomeError(scriptName: "update_property", duration: .seconds(3))
        case .cancellation:
            throw CancellationError()
        }
    }

    func batchUpdateTracks(_: [(trackID: String, property: String, value: String)]) async throws {
        Issue.record("Outcome tests do not expect batch writes")
        throw AppleScriptBatchVerificationError(
            updateCount: 1,
            failedCount: 1,
            reason: "unexpected batch write"
        )
    }
}

private func makeCoordinator(
    _ client: any AppleScriptClient,
    year: Int? = nil,
    cache: any CacheService = MockCacheService(),
    snapshot: (any LibrarySnapshotService)? = nil
) -> UpdateCoordinator {
    let scores = year.map { [$0: 90] } ?? [:]
    let api = MockAPIService(yearResult: YearResult(year: year, confidence: 90, yearScores: scores))
    let undo = makeUndoCoordinator(client, cache: cache, snapshot: snapshot)
    return UpdateCoordinator(
        dependencies: UpdateCoordinatorDependencies(
            apiOrchestrator: makeAPIOrchestrator(
                musicBrainz: api,
                discogs: api,
                appleMusic: api
            ),
            scriptBridge: client,
            trackStore: MockTrackStore(),
            cache: cache,
            undoCoordinator: undo,
            librarySnapshotService: snapshot
        ),
        genreDeterminator: GenreDeterminator()
    )
}

private func makeUndoCoordinator(
    _ client: any AppleScriptClient,
    cache: (any CacheService)? = nil,
    snapshot: (any LibrarySnapshotService)? = nil
) -> UndoCoordinator {
    UndoCoordinator(
        scriptBridge: client,
        cache: cache,
        librarySnapshotService: snapshot,
        directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("WriteOutcomeTests-\(UUID().uuidString)")
    )
}

private func makeTrack(
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
        releaseYear: releaseYear
    )
}

private func makeGenreChange(_ track: Track) -> ProposedChange {
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

private func makeYearChange(_ track: Track) -> ProposedChange {
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
