import Core
import Foundation
import Services
@testable import Genre_Updater

struct LibraryPersistenceFixture {
    let dependencies: AppDependencies
    let trackStore: SwiftDataTrackStore
    let snapshotService: SnapshotServiceSpy
}

@MainActor
func makeFixture(
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

actor RunRecordStoreStub: RunRecordStore {
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

func sampleRunRecord(
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

func sampleTrack() -> Track {
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

func mainViewDataSourceURL() throws -> URL {
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

func reportsViewSourceURL() throws -> URL {
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

actor SnapshotServiceSpy: LibrarySnapshotService {
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
