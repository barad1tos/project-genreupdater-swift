import Core
import Foundation
import Services
import SwiftData
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

        try await fixture.dependencies.persistLibraryLoad(tracks)

        #expect(await fixture.snapshotService.savedSnapshotCount() == 0)
    }

    @Test("Scoped test-artist load still persists track state")
    func scopedTestArtistLoadStillPersistsTrackState() async throws {
        let fixture = try makeFixture(testArtists: ["Clutch"])
        let tracks = [sampleTrack()]

        try await fixture.dependencies.persistLibraryLoad(tracks)

        let storedTracks = try await fixture.trackStore.loadAllTracks()
        #expect(storedTracks.map(\.id) == ["track-1"])
    }

    @Test("Full-library load saves snapshot")
    func fullLibraryLoadSavesSnapshot() async throws {
        let fixture = try makeFixture(testArtists: [])
        let tracks = [sampleTrack()]

        try await fixture.dependencies.persistLibraryLoad(tracks)

        #expect(await fixture.snapshotService.savedSnapshotCount() == 1)
        #expect(await fixture.snapshotService.savedTrackIDs() == ["track-1"])
    }

    @Test("A partial MusicKit load preserves authoritative mirror metadata")
    func partialLoadPreservesMirror() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        try await fixture.trackStore.saveTracks([
            Core.Track(
                id: "live",
                name: "Song",
                artist: "Clutch",
                album: "Blast Tyrant",
                genre: "Stoner Rock",
                year: 2004,
                trackStatus: TrackKind.purchased.rawValue,
                originalArtist: "Clutch",
                originalAlbum: "Blast Tyrant",
                yearBeforeMGU: 2003,
                yearSetByMGU: 2004,
                albumArtist: "Clutch"
            ),
        ])
        fixture.dependencies.installTestLibraryReadProvider(PartialLibraryReadProvider())

        await fixture.dependencies.loadLibrary(forceRefresh: true)

        let visibleTrack = try #require(fixture.dependencies.libraryTracks.first)
        let persistedTrack = try #require(await fixture.trackStore.getTrack(byID: "live"))
        for track in [visibleTrack, persistedTrack] {
            #expect(track.year == 2004)
            #expect(track.albumArtist == "Clutch")
            #expect(track.trackStatus == TrackKind.purchased.rawValue)
            #expect(track.originalArtist == "Clutch")
            #expect(track.originalAlbum == "Blast Tyrant")
            #expect(track.yearBeforeMGU == 2003)
            #expect(track.yearSetByMGU == 2004)
        }
    }

    @Test("A partial MusicKit load preserves authoritative metadata across relaunch")
    func mirrorSurvivesRelaunch() async throws {
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryServicesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        defer { removeStoreDirectory(storeDirectory) }
        let storeURL = storeDirectory.appendingPathComponent("GenreUpdater.store")

        do {
            let trackStore = try makeTrackStore(at: storeURL)
            try await trackStore.saveTracks([
                Core.Track(
                    id: "live",
                    name: "Song",
                    artist: "Clutch",
                    album: "Blast Tyrant",
                    year: 2004,
                    trackStatus: TrackKind.purchased.rawValue,
                    albumArtist: "Clutch"
                ),
            ])
            let dependencies = makeDependencies(trackStore: trackStore)
            dependencies.installTestLibraryReadProvider(PartialLibraryReadProvider())

            await dependencies.loadLibrary(forceRefresh: true)
        }

        let relaunchedStore = try makeTrackStore(at: storeURL)
        let persistedTrack = try #require(await relaunchedStore.getTrack(byID: "live"))
        #expect(persistedTrack.year == 2004)
        #expect(persistedTrack.albumArtist == "Clutch")
        #expect(persistedTrack.trackStatus == TrackKind.purchased.rawValue)
    }

    @Test("A mirror read failure blocks a partial MusicKit load")
    func mirrorFailureBlocksLoad() async {
        let trackStore = FailingMirrorReadStore()
        let snapshotService = SnapshotServiceSpy()
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in }
        )
        dependencies.configureLibraryPersistenceForTesting(
            trackStore: trackStore,
            librarySnapshotService: snapshotService,
            runRecordStore: RunRecordStoreStub()
        )
        dependencies.installTestLibraryReadProvider(PartialLibraryReadProvider())

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

        try await fixture.dependencies.persistLibraryLoad(tracks)

        #expect(await fixture.snapshotService.savedSnapshotCount() == 1)
    }

    @Test("Captured scoped load skips snapshot after config becomes full-library")
    func capturedScopedLoadSkipsSnapshotAfterConfigBecomesFullLibrary() async throws {
        let fixture = try makeFixture(testArtists: ["Clutch"])
        let capturedScope = ArtistAllowList.normalized(fixture.dependencies.config.development.testArtists)
        fixture.dependencies.config.development.testArtists = []

        try await fixture.dependencies.persistLibraryLoad(
            [sampleTrack()],
            scopedArtists: capturedScope
        )

        #expect(await fixture.snapshotService.savedSnapshotCount() == 0)
    }

    @Test("Library load persistence passes captured scope")
    func libraryLoadPersistencePassesCapturedScope() throws {
        let source = try String(contentsOf: libraryLoadChainSourceURL(), encoding: .utf8)
        let compactSource = source.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )

        #expect(
            compactSource.contains(
                "try await persistLibraryLoad( liveLoad.tracks, scopedArtists: scopedArtists )"
            )
        )
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
private func makeDependencies(trackStore: TrackDataStore) -> AppDependencies {
    let dependencies = AppDependencies(
        configurationLoader: { AppConfiguration() },
        configurationSaver: { _ in }
    )
    dependencies.configureLibraryPersistenceForTesting(
        trackStore: trackStore,
        librarySnapshotService: SnapshotServiceSpy(),
        runRecordStore: RunRecordStoreStub()
    )
    return dependencies
}

private func makeTrackStore(at storeURL: URL) throws -> TrackDataStore {
    let schema = Schema([PersistedTrack.self, PersistedChangeLogEntry.self])
    let configuration = ModelConfiguration(
        "LibraryServicesTests",
        schema: schema,
        url: storeURL,
        cloudKitDatabase: .none
    )
    let container = try ModelContainer(for: schema, configurations: [configuration])
    return TrackDataStore(modelContainer: container)
}

private func removeStoreDirectory(_ directory: URL) {
    do {
        try FileManager.default.removeItem(at: directory)
    } catch {
        Issue.record("Failed to remove library services fixture: \(error)")
    }
}

private actor PartialLibraryReadProvider: LibraryReadProvider {
    func loadLibrarySnapshot(request _: LibraryReadRequest) async throws -> LibraryReadSnapshot {
        LibraryReadSnapshot(tracks: [
            Core.Track(id: "live", name: "Song", artist: "Clutch", album: "Blast Tyrant"),
        ], scannedAt: Date(timeIntervalSince1970: 200))
    }
}

private actor FailingMirrorReadStore: TrackStateStore {
    private var savedTracks: [Core.Track] = []

    func initialize() async throws {}

    func loadAllTracks() async throws -> [Core.Track] {
        throw MirrorReadError()
    }

    func saveTracks(_ tracks: [Core.Track]) async throws {
        savedTracks.append(contentsOf: tracks)
    }

    func deleteTrackIDs(_: [String]) async throws -> Int {
        0
    }
    func getTrack(byID _: String) async throws -> Core.Track? {
        nil
    }
    func persistAppliedChange(_: ChangeLogEntry) async throws {}
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
