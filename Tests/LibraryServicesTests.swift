import Core
import CryptoKit
import Foundation
import Services
import Testing
@testable import Genre_Updater

private let expectedOpenRunStates: Set<RunLifecycleState> = [
    .created,
    .queued,
    .syncingLibrary,
    .analyzingDelta,
    .planningFixes,
    .awaitingReview,
    .writing,
    .verifying,
    .reporting,
    .blocked,
    .recoverable,
    .recovering
]
@Suite("AppDependencies library services")
@MainActor
struct LibraryServicesTests {
    @Test("Scoped test-artist load skips full-library snapshot")
    func scopedTestArtistLoadSkipsFullLibrarySnapshot() async throws {
        let fixture = try makeFixture(testArtists: ["Clutch"])
        let tracks = [sampleTrack()]

        await fixture.dependencies.cacheLibraryLoad(tracks)

        #expect(await fixture.snapshotService.savedSnapshotCount() == 0)
    }

    @Test("Full-library snapshot caching saves once without mutating processing track state")
    func cacheIsolation() async throws {
        let fixture = try makeFixture(testArtists: [])
        let tracks = [sampleTrack()]

        await fixture.dependencies.cacheLibraryLoad(tracks)

        let storedTracks = try await fixture.trackStore.loadAllTracks()
        #expect(await fixture.snapshotService.savedSnapshotCount() == 1)
        #expect(storedTracks.isEmpty)
    }

    @Test("Full-library load saves snapshot")
    func fullLibraryLoadSavesSnapshot() async throws {
        let fixture = try makeFixture(testArtists: [])
        let tracks = [sampleTrack()]

        await fixture.dependencies.cacheLibraryLoad(tracks)

        #expect(await fixture.snapshotService.savedSnapshotCount() == 1)
        #expect(await fixture.snapshotService.savedTrackIDs() == ["track-1"])
    }

    @Test("A seeded empty mirror replaces cached presentation tracks")
    func seededEmptyWins() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        let metricsStore = try MetricsSnapshotStore(modelContainer: ModelContainerFactory.createInMemory())
        await metricsStore.upsert(from: [canonicalMirrorTrack(sampleTrack())])
        await fixture.snapshotService.installSnapshot([
            canonicalMirrorTrack(sampleTrack()),
        ])
        fixture.dependencies.configureLibraryPersistenceForTesting(
            trackStore: MirrorTrackStoreStub(tracks: [], isSeeded: true),
            librarySnapshotService: fixture.snapshotService,
            metricsSnapshotStore: metricsStore,
            runRecordStore: RunRecordStoreStub()
        )
        var browsedTrackIDs: [[String]] = []
        fixture.dependencies.applyBrowseTruthForLoad = { tracks, _, _ in
            browsedTrackIDs.append(tracks.map(\.id))
        }
        var appliedTrackIDs: [[String]] = []
        fixture.dependencies.onLibraryLoadApplied = { tracks in
            appliedTrackIDs.append(tracks.map(\.id))
        }

        await fixture.dependencies.loadLibrary()

        #expect(fixture.dependencies.libraryTracks.isEmpty)
        #expect(fixture.dependencies.isLibraryReadyForUpdates)
        #expect(await fixture.snapshotService.savedSnapshotCount() == 1)
        #expect(await fixture.snapshotService.savedTrackIDs().isEmpty)
        #expect(browsedTrackIDs == [["track-1"], []])
        #expect(appliedTrackIDs == [["track-1"], []])
        #expect(fixture.dependencies.libraryMetrics == nil)
        #expect(await metricsStore.loadLatest() == nil)
    }

    @Test("Canonical mirror metadata is the only library and processing input")
    func keepsProcessingState() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        try await fixture.trackStore.seedMirror([
            Core.Track(
                id: "live",
                name: "Song",
                artist: "Clutch (Original Credit)",
                album: "Blast Tyrant (Original Title)",
                genre: "Stoner Rock",
                year: 2003,
                trackStatus: TrackKind.purchased.rawValue,
                albumArtist: "Clutch"
            ),
        ])
        var yearChange = ChangeLogEntry(
            changeType: .yearUpdate,
            trackID: "live",
            artist: "Clutch",
            trackName: "Song",
            albumName: "Blast Tyrant"
        )
        yearChange.oldYear = 2003
        yearChange.newYear = 2004
        try await fixture.trackStore.persistAppliedChange(yearChange)

        var artistChange = ChangeLogEntry(
            changeType: .artistRename,
            trackID: "live",
            artist: "Clutch",
            trackName: "Song",
            albumName: "Blast Tyrant"
        )
        artistChange.oldArtist = "Clutch (Original Credit)"
        artistChange.newArtist = "Clutch"
        try await fixture.trackStore.persistAppliedChange(artistChange)

        var albumChange = ChangeLogEntry(
            changeType: .albumCleaning,
            trackID: "live",
            artist: "Clutch",
            trackName: "Song",
            albumName: "Blast Tyrant"
        )
        albumChange.oldAlbumName = "Blast Tyrant (Original Title)"
        albumChange.newAlbumName = "Blast Tyrant"
        try await fixture.trackStore.persistAppliedChange(albumChange)
        await fixture.dependencies.loadLibrary(forceRefresh: true)

        let visibleTrack = try #require(fixture.dependencies.libraryTracks.first)
        let persistedTrack = try #require(await fixture.trackStore.getTrack(byID: "live"))
        #expect(visibleTrack.year == 2004)
        #expect(visibleTrack.albumArtist == "Clutch")
        #expect(visibleTrack.trackStatus == TrackKind.purchased.rawValue)
        #expect(persistedTrack.year == 2004)
        #expect(persistedTrack.albumArtist == "Clutch")
        #expect(persistedTrack.trackStatus == TrackKind.purchased.rawValue)
        #expect(persistedTrack.originalArtist == "Clutch (Original Credit)")
        #expect(persistedTrack.originalAlbum == "Blast Tyrant (Original Title)")
        #expect(persistedTrack.yearBeforeMGU == 2003)
        #expect(persistedTrack.yearSetByMGU == 2004)
    }

    @Test("A canonical mirror genre change remains visible and enters incremental scope")
    func genreEditEntersScope() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        await fixture.snapshotService.installSnapshot([
            canonicalMirrorTrack(Core.Track(
                id: "live",
                name: "Song",
                artist: "Clutch",
                album: "Blast Tyrant",
                genre: "Metal"
            )),
        ])
        try await fixture.trackStore.seedMirror([
            Core.Track(
                id: "live",
                name: "Song",
                artist: "Clutch",
                album: "Blast Tyrant",
                genre: "Alternative"
            ),
        ])

        await fixture.dependencies.loadLibrary()

        let visibleTrack = try #require(fixture.dependencies.libraryTracks.first)
        let incrementalTracks = UpdateTrackScopeResolver.incrementalTracks(
            fixture.dependencies.libraryTracks,
            lastRunTime: Date(),
            previousTracks: fixture.dependencies.previousIncrementalScopeTracks,
            options: IncrementalTrackScopeOptions(updateGenre: false)
        )
        #expect(visibleTrack.genre == "Alternative")
        #expect(fixture.dependencies.previousIncrementalScopeTracks.first?.genre == "Metal")
        #expect(try await fixture.trackStore.loadAllTracks().map(\.genre) == ["Alternative"])
        #expect(incrementalTracks.map(\.id) == ["live"])
    }

    @Test("A legacy zero-year snapshot rebuilds once and loads canonically after relaunch")
    func rebuildsZeroSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibrarySnapshotUpgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { removeStoreDirectory(directory) }
        let cachePath = directory.appendingPathComponent("cache.sqlite").path
        let configuration = LibrarySnapshotConfig()
        let snapshotDate = Date(timeIntervalSince1970: 1_800_000_000)
        do {
            let cache = try GRDBCacheService(databasePath: cachePath)
            try await cache.initialize()
            let snapshotService = try await seedLegacySnapshot(
                cache: cache,
                configuration: configuration,
                date: snapshotDate
            )
            let trackStore = try TrackDataStore.createInMemory()
            try await trackStore.initialize()
            try await trackStore.seedMirror([
                Core.Track(
                    id: "T1",
                    name: "Angel",
                    artist: "Massive Attack",
                    album: "Mezzanine",
                    year: 0,
                    releaseYear: 0
                ),
            ])
            let dependencies = makeDependencies(
                trackStore: trackStore,
                snapshotService: snapshotService
            )

            await dependencies.loadLibrary()

            #expect(dependencies.libraryTracks.first?.year == nil)
            #expect(dependencies.libraryTracks.first?.releaseYear == nil)
            let rebuilt = try #require(try await snapshotService.loadSnapshot()?.first)
            #expect(rebuilt.year == nil)
            #expect(rebuilt.releaseYear == nil)
        }

        do {
            let cache = try GRDBCacheService(databasePath: cachePath)
            try await cache.initialize()
            let snapshotService = CachedLibrarySnapshotService(
                cache: cache,
                configuration: configuration,
                currentDate: { snapshotDate }
            )
            let dependencies = try makeDependencies(
                trackStore: TrackDataStore.createInMemory(),
                snapshotService: snapshotService
            )

            await dependencies.loadLibrary()

            let cachedTrack = try #require(dependencies.libraryTracks.first)
            #expect(cachedTrack.year == nil)
            #expect(cachedTrack.releaseYear == nil)
        }
    }

    @Test("Processing mirror failures surface an actionable library error")
    func surfacesMirrorFailure() async {
        let trackStore = FailingMirrorReadStore()
        let snapshotService = SnapshotServiceSpy()
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in
                // This load-failure test never mutates configuration.
            }
        )
        dependencies.configureLibraryPersistenceForTesting(
            trackStore: trackStore,
            librarySnapshotService: snapshotService,
            runRecordStore: RunRecordStoreStub()
        )
        await dependencies.loadLibrary(forceRefresh: true)

        #expect(dependencies.libraryTracks.isEmpty)
        #expect(dependencies.libraryLoadError?.message == "mirror read failed")
        #expect(!dependencies.isLibraryReadyForUpdates)
        #expect(await trackStore.savedTrackCount() == 0)
        #expect(await snapshotService.savedSnapshotCount() == 0)
    }

    @Test("Blank-only test artists save full-library snapshot")
    func blankOnlyTestArtistsSaveFullLibrarySnapshot() async throws {
        let fixture = try makeFixture(testArtists: ["  "])
        let tracks = [sampleTrack()]

        await fixture.dependencies.cacheLibraryLoad(tracks)

        #expect(await fixture.snapshotService.savedSnapshotCount() == 1)
    }

    @Test("Captured scoped load skips snapshot after config becomes full-library")
    func capturedScopedLoadSkipsSnapshotAfterConfigBecomesFullLibrary() async throws {
        let fixture = try makeFixture(testArtists: ["Clutch"])
        let capturedScope = ArtistAllowList.normalized(fixture.dependencies.config.development.testArtists)
        fixture.dependencies.config.development.testArtists = []

        await fixture.dependencies.cacheLibraryLoad(
            [sampleTrack()],
            scopedArtists: capturedScope
        )

        #expect(await fixture.snapshotService.savedSnapshotCount() == 0)
    }

    @Test("Malformed run report id returns nil")
    func malformedRunReportIDReturnsNil() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())

        let record = await fixture.dependencies.loadRunReportRecord(id: "not-a-uuid")

        #expect(record == nil)
    }

    @Test("Missing run record store returns nil")
    func missingRunRecordStoreReturnsNil() async throws {
        let fixture = try makeFixture(testArtists: [])

        let record = await fixture.dependencies.loadRunReportRecord(id: UUID().uuidString)

        #expect(record == nil)
    }

    @Test("Missing run record store returns nil run report page")
    func missingRunRecordStoreReturnsNilRunReportPage() async throws {
        let fixture = try makeFixture(testArtists: [])

        let page = await fixture.dependencies.loadRunReportPage(limit: 10)

        #expect(page == nil)
    }

    @Test("Run report page store failure returns nil")
    func runReportPageStoreFailureReturnsNil() async throws {
        let fixture = try makeFixture(
            testArtists: [],
            runRecordStore: RunRecordStoreStub(reportsError: CocoaError(.fileReadCorruptFile))
        )

        let page = await fixture.dependencies.loadRunReportPage(limit: 10)

        #expect(page == nil)
    }

    @Test("Run report page passes store results and limit through")
    func runReportPagePassesStoreResultsAndLimitThrough() async throws {
        let record = sampleRunRecord()
        let recentCorruptedID = RunID()
        let openCorruptedID = RunID()
        let closableRunID = RunID()
        let attentionRunID = RunID()
        let unsupportedRunID = RunID()
        let stub = RunRecordStoreStub(reportPages: [
            RunReportPage(
                records: [record],
                skippedCorruptedCount: 2,
                corruptedRunIDs: [recentCorruptedID, openCorruptedID],
                recoveryRunIDs: [openCorruptedID]
            ),
            RunReportPage(
                records: [],
                skippedCorruptedCount: 2,
                corruptedRunIDs: [recentCorruptedID, openCorruptedID],
                recoveryRunIDs: [openCorruptedID]
            ),
        ], recoveryPage: RunReportPage(
            records: [],
            skippedCorruptedCount: 1,
            corruptedRunIDs: [openCorruptedID],
            recoveryRunIDs: [openCorruptedID],
            closableRunIDs: [closableRunID],
            attentionRunIDs: [attentionRunID],
            unsupportedRunIDs: [unsupportedRunID]
        ))
        let fixture = try makeFixture(testArtists: [], runRecordStore: stub)

        let page = await fixture.dependencies.loadRunReportPage(limit: 25)
        let queries = await stub.reportQueries()

        #expect(page?.records.map(\.runID) == [record.runID])
        #expect(page?.skippedCorruptedCount == 2)
        #expect(page?.corruptedRunIDs == [recentCorruptedID, openCorruptedID])
        #expect(page?.recoveryRunIDs == [openCorruptedID])
        #expect(page?.closableRunIDs == [closableRunID])
        #expect(page?.attentionRunIDs == [attentionRunID])
        #expect(page?.unsupportedRunIDs == [unsupportedRunID])
        #expect(page?.unresolvedRunIDs == [openCorruptedID, attentionRunID, unsupportedRunID])
        #expect(queries.first?.limit == 25)
    }

    @Test("Run report page includes old corrupted recovery rows")
    func includesOldCorruptedRecovery() async throws {
        let recent = sampleRunRecord()
        let recoveryRunID = RunID()
        let stub = RunRecordStoreStub(
            reportPages: [
                RunReportPage(records: [recent], skippedCorruptedCount: 0),
                RunReportPage(records: [], skippedCorruptedCount: 0),
            ],
            recoveryPage: RunReportPage(
                records: [],
                skippedCorruptedCount: 1,
                corruptedRunIDs: [recoveryRunID],
                recoveryRunIDs: [recoveryRunID]
            )
        )
        let fixture = try makeFixture(testArtists: [], runRecordStore: stub)

        let page = await fixture.dependencies.loadRunReportPage(limit: 1)

        #expect(page?.records.map(\.runID) == [recent.runID])
        #expect(page?.recoveryRunIDs == [recoveryRunID])
        #expect(page?.skippedCorruptedCount == 1)
    }

    @Test("Run report page includes open records outside the capped history")
    func includesOpenRuns() async throws {
        let recent = sampleRunRecord()
        let openRecord = sampleRunRecord(
            runID: RunID(),
            state: .reporting,
            finishedAt: nil
        )
        let stub = RunRecordStoreStub(reportPages: [
            RunReportPage(records: [recent], skippedCorruptedCount: 1),
            RunReportPage(records: [openRecord], skippedCorruptedCount: 0),
        ])
        let fixture = try makeFixture(testArtists: [], runRecordStore: stub)

        let page = await fixture.dependencies.loadRunReportPage(limit: 1)
        let queries = await stub.reportQueries()

        #expect(page?.records.map(\.runID) == [recent.runID, openRecord.runID])
        #expect(page?.skippedCorruptedCount == 1)
        #expect(queries.map(\.limit) == [1, nil])
        #expect(queries.last?.states == expectedOpenRunStates)
    }

    @Test("Recovery hold ignores normal active runs")
    func normalRunDoesNotHold() async throws {
        let activeRecord = sampleRunRecord(
            runID: RunID(),
            state: .syncingLibrary,
            finishedAt: nil
        )
        let stub = RunRecordStoreStub(reportPage: RunReportPage(records: [activeRecord], skippedCorruptedCount: 0))
        let fixture = try makeFixture(testArtists: [], runRecordStore: stub)

        let isHeld = await fixture.dependencies.ensureRecoveryHold()

        #expect(!isHeld)
    }

    @Test("Recovery hold is active for open recovery records")
    func recoveryRecordHoldsWrites() async throws {
        let recoverableRecord = sampleRunRecord(
            runID: RunID(),
            intent: .writeFixes,
            state: .recoverable,
            finishedAt: nil
        )
        let stub = RunRecordStoreStub(
            storedRecord: recoverableRecord,
            reportPage: RunReportPage(records: [recoverableRecord], skippedCorruptedCount: 0)
        )
        let fixture = try makeFixture(testArtists: [], runRecordStore: stub)

        let isHeld = await fixture.dependencies.ensureRecoveryHold()

        #expect(isHeld)
    }

    @Test("Recovery hold is active for attention records")
    func attentionRecordHolds() async throws {
        let runID = RunID()
        let stub = RunRecordStoreStub(reportPage: RunReportPage(
            records: [],
            skippedCorruptedCount: 1,
            attentionRunIDs: [runID]
        ))
        let fixture = try makeFixture(testArtists: [], runRecordStore: stub)

        let isHeld = await fixture.dependencies.ensureRecoveryHold()

        #expect(isHeld)
    }

    @Test("Recovery hold fails closed when run records cannot be read")
    func recoveryHoldFailsClosedOnStoreError() async throws {
        let fixture = try makeFixture(
            testArtists: [],
            runRecordStore: RunRecordStoreStub(reportsError: CocoaError(.fileReadCorruptFile))
        )

        let isHeld = await fixture.dependencies.ensureRecoveryHold()

        #expect(isHeld)
    }

    @Test("Recovery hold fails closed for skipped corrupted run rows")
    func recoveryHoldFailsClosedOnSkippedCorruptedRows() async throws {
        let runID = RunID()
        let stub = RunRecordStoreStub(reportPage: RunReportPage(
            records: [],
            skippedCorruptedCount: 1,
            recoveryRunIDs: [runID]
        ))
        let fixture = try makeFixture(testArtists: [], runRecordStore: stub)

        let isHeld = await fixture.dependencies.ensureRecoveryHold()

        #expect(isHeld)
    }

    @Test("Run report record store failure returns nil")
    func runReportRecordStoreFailureReturnsNil() async throws {
        let fixture = try makeFixture(
            testArtists: [],
            runRecordStore: RunRecordStoreStub(recordError: CocoaError(.fileReadCorruptFile))
        )

        let record = await fixture.dependencies.loadRunReportRecord(id: UUID().uuidString)

        #expect(record == nil)
    }

    @Test("Run report record returns the stored record for a valid id")
    func runReportRecordReturnsStoredRecordForValidID() async throws {
        let record = sampleRunRecord()
        let fixture = try makeFixture(
            testArtists: [],
            runRecordStore: RunRecordStoreStub(storedRecord: record)
        )

        let loaded = await fixture.dependencies.loadRunReportRecord(id: record.runID.rawValue.uuidString)

        #expect(loaded?.runID == record.runID)
    }

    @Test("Recovery preflight returns blocked without run record store")
    func missingStoreBlocks() async throws {
        let fixture = try makeFixture(testArtists: [])
        let runID = RunID()

        let outcome = await fixture.dependencies.runRecoveryPreflight(runID: runID)

        #expect(outcome == .blocked(runID: runID, reason: .storeUnavailable))
    }

    @Test("Recovery preflight uses run record store")
    func preflightUsesStore() async throws {
        let record = sampleRunRecord(
            runID: RunID(),
            state: .syncingLibrary,
            finishedAt: nil
        )
        let fixture = try makeFixture(
            testArtists: [],
            runRecordStore: RunRecordStoreStub(storedRecord: record)
        )

        let outcome = await fixture.dependencies.runRecoveryPreflight(runID: record.runID)

        #expect(outcome == .inspectable(runID: record.runID, state: .syncingLibrary))
    }

    @Test("Submit preview run requires a run orchestrator")
    func previewRequiresOrchestrator() async throws {
        let fixture = try makeFixture(testArtists: [])

        await #expect(throws: AppDependencyServiceError.runOrchestratorUnavailable) {
            try await fixture.dependencies.submitPreviewRun()
        }
    }

    @Test("Continuation lookup failures degrade to an empty lineage")
    func continuationLookupFailureDegradesToEmpty() async throws {
        let store = RunRecordStoreStub()
        await store.failContinuations()
        let fixture = try makeFixture(testArtists: [], runRecordStore: store)

        let continuations = await fixture.dependencies.loadRunContinuations(id: UUID().uuidString)

        #expect(continuations.isEmpty)
    }

    @Test("A malformed run id yields no continuations")
    func malformedRunIDYieldsNoContinuations() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())

        let continuations = await fixture.dependencies.loadRunContinuations(id: "not-a-uuid")

        #expect(continuations.isEmpty)
    }
}

@MainActor
private func makeDependencies(
    trackStore: TrackDataStore,
    snapshotService: any LibrarySnapshotService = SnapshotServiceSpy()
) -> AppDependencies {
    let dependencies = AppDependencies(
        configurationLoader: { AppConfiguration() },
        configurationSaver: { _ in
            // Relaunch fixtures exercise track persistence only.
        }
    )
    dependencies.configureLibraryPersistenceForTesting(
        trackStore: trackStore,
        librarySnapshotService: snapshotService,
        runRecordStore: RunRecordStoreStub()
    )
    return dependencies
}

private func removeStoreDirectory(_ directory: URL) {
    do {
        try FileManager.default.removeItem(at: directory)
    } catch {
        Issue.record("Failed to remove library services fixture: \(error)")
    }
}

private struct LegacySnapshotTrack: Codable, Sendable {
    let id: String
    let name: String
    let artist: String
    let album: String
    let year: Int
    let releaseYear: Int
}

private func seedLegacySnapshot(
    cache: GRDBCacheService,
    configuration: LibrarySnapshotConfig,
    date: Date
) async throws -> CachedLibrarySnapshotService {
    let tracks = [LegacySnapshotTrack(
        id: "T1",
        name: "Angel",
        artist: "Massive Attack",
        album: "Mezzanine",
        year: 0,
        releaseYear: 0
    )]
    let namespace = "library-snapshot:\(configuration.cacheFile)"
    await cache.setPersistent(key: "\(namespace):tracks", value: tracks)
    let service = CachedLibrarySnapshotService(
        cache: cache,
        configuration: configuration,
        currentDate: { date }
    )
    try await service.updateSnapshotMetadata(LibraryCacheMetadata(
        trackCount: tracks.count,
        snapshotHash: legacySnapshotHash(for: tracks),
        timestamp: date,
        libraryModificationDate: date
    ))
    return service
}

private func legacySnapshotHash(for tracks: [LegacySnapshotTrack]) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(tracks.sorted { $0.id < $1.id })
    return SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
}

private actor FailingMirrorReadStore: TrackStateStore {
    private var savedTracks: [Core.Track] = []

    func initialize() async throws {
        // The failure double has no backing store to initialize.
    }

    func loadAllTracks() async throws -> [Core.Track] {
        throw MirrorReadError()
    }

    func loadMirrorSnapshot() async throws -> TrackMirrorSnapshot {
        throw MirrorReadError()
    }

    func applyMirror(_ update: TrackMirrorUpdate) async throws {
        savedTracks.append(contentsOf: update.upserts)
    }

    func getTrack(byID _: String) async throws -> Core.Track? {
        nil
    }
    func persistAppliedChange(_: ChangeLogEntry) async throws {
        // Library loading never persists change-log entries.
    }
    func getUnprocessedTracks() async throws -> [Core.Track] {
        []
    }
    func trackCount() async throws -> Int {
        0
    }
    func savedTrackCount() -> Int {
        savedTracks.count
    }
}

private struct MirrorReadError: LocalizedError {
    var errorDescription: String? {
        "mirror read failed"
    }
}
