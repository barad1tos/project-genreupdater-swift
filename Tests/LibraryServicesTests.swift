import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("AppDependencies library services")
@MainActor
struct LibraryServicesTests {
    @Test("Scoped test-artist load skips full-library snapshot")
    func scopedTestArtistLoadSkipsFullLibrarySnapshot() async throws {
        let fixture = try makeFixture(testArtists: ["Clutch"])
        let tracks = [sampleTrack()]

        await fixture.dependencies.persistLoadedLibraryTracks(tracks)

        #expect(await fixture.snapshotService.savedSnapshotCount() == 0)
    }

    @Test("Scoped test-artist load still persists track state")
    func scopedTestArtistLoadStillPersistsTrackState() async throws {
        let fixture = try makeFixture(testArtists: ["Clutch"])
        let tracks = [sampleTrack()]

        await fixture.dependencies.persistLoadedLibraryTracks(tracks)

        let storedTracks = try await fixture.trackStore.loadAllTracks()
        #expect(storedTracks.map(\.id) == ["track-1"])
    }

    @Test("Full-library load saves snapshot")
    func fullLibraryLoadSavesSnapshot() async throws {
        let fixture = try makeFixture(testArtists: [])
        let tracks = [sampleTrack()]

        await fixture.dependencies.persistLoadedLibraryTracks(tracks)

        #expect(await fixture.snapshotService.savedSnapshotCount() == 1)
        #expect(await fixture.snapshotService.savedTrackIDs() == ["track-1"])
    }

    @Test("Blank-only test artists save full-library snapshot")
    func blankOnlyTestArtistsSaveFullLibrarySnapshot() async throws {
        let fixture = try makeFixture(testArtists: ["  "])
        let tracks = [sampleTrack()]

        await fixture.dependencies.persistLoadedLibraryTracks(tracks)

        #expect(await fixture.snapshotService.savedSnapshotCount() == 1)
    }

    @Test("Captured scoped load skips snapshot after config becomes full-library")
    func capturedScopedLoadSkipsSnapshotAfterConfigBecomesFullLibrary() async throws {
        let fixture = try makeFixture(testArtists: ["Clutch"])
        let capturedScope = ArtistAllowList.normalized(fixture.dependencies.config.development.testArtists)
        fixture.dependencies.config.development.testArtists = []

        await fixture.dependencies.persistLoadedLibraryTracks(
            [sampleTrack()],
            scopedArtists: capturedScope
        )

        #expect(await fixture.snapshotService.savedSnapshotCount() == 0)
    }

    @Test("MainView load persistence passes captured scope")
    func mainViewLoadPersistencePassesCapturedScope() throws {
        let source = try String(contentsOf: mainViewDataSourceURL(), encoding: .utf8)
        let compactSource = source.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )

        #expect(
            compactSource.contains(
                "await dependencies.persistLoadedLibraryTracks(liveLoad.tracks, scopedArtists: scopedArtists)"
            )
        )
    }

    @Test("Reports backup import propagates mapping refresh errors")
    func reportsBackupImportPropagatesMappingRefreshErrors() throws {
        let source = try String(contentsOf: reportsViewSourceURL(), encoding: .utf8)
        let compactSource = source.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )

        #expect(
            compactSource.contains(
                [
                    "let mappedTrackCount = try await dependencies.refreshTrackIDMappingOrThrow(",
                    "musicKitTracks: tracks,",
                    "scopedArtists: [artist],",
                    "mergeExisting: true",
                    ")",
                ].joined(separator: " ")
            )
        )
        #expect(
            compactSource.contains(
                [
                    "guard mappedTrackCount > 0 || tracks.isEmpty else {",
                    "throw BackupCSVImportError.noWritableTrackMapping",
                    "}",
                ].joined(separator: " ")
            )
        )
    }

    @Test("Reports backup import title distinguishes failed and partial reverts")
    func reportsBackupImportTitleDistinguishesFailedAndPartialReverts() {
        #expect(backupImportAlertTitle(for: YearBackupRevertResult(
            parsedCount: 1,
            updatedCount: 0,
            skippedCount: 0,
            missingCount: 0,
            failedCount: 1
        )) == "Revert Failed")

        #expect(backupImportAlertTitle(for: YearBackupRevertResult(
            parsedCount: 2,
            updatedCount: 1,
            skippedCount: 0,
            missingCount: 0,
            failedCount: 1
        )) == "Revert Partial")

        #expect(backupImportAlertTitle(for: YearBackupRevertResult(
            parsedCount: 1,
            updatedCount: 1,
            skippedCount: 0,
            missingCount: 0,
            failedCount: 0
        )) == "Revert Complete")
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
        let stub = RunRecordStoreStub(reportPages: [
            RunReportPage(records: [record], skippedCorruptedCount: 2),
            RunReportPage(records: [], skippedCorruptedCount: 0),
        ])
        let fixture = try makeFixture(testArtists: [], runRecordStore: stub)

        let page = await fixture.dependencies.loadRunReportPage(limit: 25)
        let queries = await stub.reportQueries()

        #expect(page?.records.map(\.runID) == [record.runID])
        #expect(page?.skippedCorruptedCount == 2)
        #expect(queries.first?.limit == 25)
    }

    @Test("Run report page includes open records outside the capped history")
    func includesOlderOpenRuns() async throws {
        let recent = sampleRunRecord()
        let open = sampleRunRecord(
            runID: RunID(),
            state: .reporting,
            finishedAt: nil
        )
        let stub = RunRecordStoreStub(reportPages: [
            RunReportPage(records: [recent], skippedCorruptedCount: 1),
            RunReportPage(records: [open], skippedCorruptedCount: 0),
        ])
        let fixture = try makeFixture(testArtists: [], runRecordStore: stub)

        let page = await fixture.dependencies.loadRunReportPage(limit: 1)
        let queries = await stub.reportQueries()

        #expect(page?.records.map(\.runID) == [recent.runID, open.runID])
        #expect(page?.skippedCorruptedCount == 1)
        #expect(queries.map(\.limit) == [1, nil])
        #expect(queries.last?.states == [.created, .syncingLibrary, .planningFixes, .reporting])
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

    @Test("Submit preview run requires a run orchestrator")
    func previewRequiresOrchestrator() async throws {
        let fixture = try makeFixture(testArtists: [])

        await #expect(throws: AppDependencyServiceError.runOrchestratorUnavailable) {
            try await fixture.dependencies.submitPreviewRun()
        }
    }

    @Test("Reports backup import message includes safe first failure")
    func reportsBackupImportMessageIncludesSafeFirstFailure() {
        let result = YearBackupRevertResult(
            parsedCount: 1,
            updatedCount: 0,
            skippedCount: 0,
            missingCount: 0,
            failedCount: 1,
            firstFailureDescription: "Missing AppleScript ID mapping for a track"
        )

        let message = backupImportMessage(for: result)

        #expect(message.contains("First failure: Missing AppleScript ID mapping for a track."))
        #expect(!message.contains("MK1"))
    }
}

private struct LibraryPersistenceFixture {
    let dependencies: AppDependencies
    let trackStore: SwiftDataTrackStore
    let snapshotService: SnapshotServiceSpy
}

@MainActor
private func makeFixture(
    testArtists: [String],
    runRecordStore: (any RunRecordStore)? = nil
) throws -> LibraryPersistenceFixture {
    let trackStore = try SwiftDataTrackStore.createInMemory()
    let snapshotService = SnapshotServiceSpy()
    let dependencies = AppDependencies(
        configurationLoader: {
            var configuration = AppConfiguration()
            configuration.development.testArtists = testArtists
            return configuration
        },
        configurationSaver: { _ in
            // Tests keep configuration in memory.
        }
    )
    dependencies.configureLibraryPersistenceForTesting(
        trackStore: trackStore,
        librarySnapshotService: snapshotService,
        runRecordStore: runRecordStore
    )
    return LibraryPersistenceFixture(
        dependencies: dependencies,
        trackStore: trackStore,
        snapshotService: snapshotService
    )
}

private actor RunRecordStoreStub: RunRecordStore {
    private let reportsError: (any Error)?
    private let recordError: (any Error)?
    private let storedRecord: RunRecord?
    private let reportPages: [RunReportPage]
    private var receivedReportQueries: [RunReportQuery] = []

    init(
        reportsError: (any Error)? = nil,
        recordError: (any Error)? = nil,
        storedRecord: RunRecord? = nil,
        reportPage: RunReportPage? = nil,
        reportPages: [RunReportPage]? = nil
    ) {
        self.reportsError = reportsError
        self.recordError = recordError
        self.storedRecord = storedRecord
        self.reportPages = reportPages ?? reportPage.map { [$0] } ?? []
    }

    func upsert(_: RunRecord) async throws {
        // Not exercised by the run report accessor test paths.
    }

    func loadAll() async throws -> [RunRecord] {
        []
    }

    func record(for runID: RunID) async throws -> RunRecord? {
        if let recordError {
            throw recordError
        }
        guard let storedRecord, storedRecord.runID == runID else { return nil }
        return storedRecord
    }

    func prune(keepingLatest _: Int) async throws -> Int {
        0
    }

    func reports(matching query: RunReportQuery) async throws -> RunReportPage {
        receivedReportQueries.append(query)
        if let reportsError {
            throw reportsError
        }
        guard !reportPages.isEmpty else {
            return RunReportPage(records: [], skippedCorruptedCount: 0)
        }
        return reportPages[min(receivedReportQueries.count - 1, reportPages.count - 1)]
    }

    func lastReportQuery() -> RunReportQuery? {
        receivedReportQueries.last
    }

    func reportQueries() -> [RunReportQuery] {
        receivedReportQueries
    }
}

private func sampleRunRecord(
    runID: RunID = RunID(),
    state: RunLifecycleState = .completed,
    finishedAt: Date? = Date(timeIntervalSince1970: 1_800_000_045)
) -> RunRecord {
    let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    return RunRecord(
        runID: runID,
        requestID: RunRequestID(),
        trigger: .manualCheck,
        intent: .observeLibrary,
        scope: ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: nil,
            createdAt: startedAt,
            reason: "manualCheck"
        ),
        transitions: [RunLifecycleTransition(state: state, timestamp: startedAt)],
        syncSummary: nil,
        failureMessage: nil,
        startedAt: startedAt,
        finishedAt: finishedAt
    )
}

private func sampleTrack() -> Track {
    Track(
        id: "track-1",
        name: "Electric Worry",
        artist: "Clutch",
        album: "From Beale Street to Oblivion",
        genre: "Rock",
        year: 2007,
        trackStatus: "purchased"
    )
}

private func mainViewDataSourceURL() throws -> URL {
    var currentURL = URL(fileURLWithPath: #filePath)
    currentURL.deleteLastPathComponent()

    for _ in 0 ..< 8 {
        let candidate = currentURL.appendingPathComponent("App/Views/MainView+Data.swift")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        currentURL.deleteLastPathComponent()
    }

    throw CocoaError(.fileNoSuchFile)
}

private func reportsViewSourceURL() throws -> URL {
    var currentURL = URL(fileURLWithPath: #filePath)
    currentURL.deleteLastPathComponent()

    for _ in 0 ..< 8 {
        let candidate = currentURL.appendingPathComponent("App/Views/ReportsView.swift")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        currentURL.deleteLastPathComponent()
    }

    throw CocoaError(.fileNoSuchFile)
}

private actor SnapshotServiceSpy: LibrarySnapshotService {
    var isEnabled = true
    var isDeltaEnabled = true
    private var saveSnapshotCallCount = 0
    private var savedTracks: [Track] = []

    func loadSnapshot() async throws -> [Track]? {
        nil
    }

    func saveSnapshot(_ tracks: [Track]) async throws -> String {
        saveSnapshotCallCount += 1
        savedTracks = tracks
        return "snapshot"
    }

    func clearSnapshot() async {
        // Snapshot clearing is outside this spy's assertions.
    }

    func isSnapshotValid() async -> Bool {
        true
    }

    func getSnapshotMetadata() async -> LibraryCacheMetadata? {
        nil
    }

    func updateSnapshotMetadata(_: LibraryCacheMetadata) async throws {
        // Metadata writes are outside this spy's assertions.
    }

    func loadDelta() async -> LibraryDeltaCache? {
        nil
    }

    func saveDelta(_: LibraryDeltaCache) async throws {
        // Delta writes are outside this spy's assertions.
    }

    func getLibraryModificationDate() async throws -> Date {
        .distantPast
    }

    func savedSnapshotCount() -> Int {
        saveSnapshotCallCount
    }

    func savedTrackIDs() -> [String] {
        savedTracks.map(\.id)
    }
}
