import Core
import Foundation
import Services
@testable import Genre_Updater

struct LibraryPersistenceFixture {
    let dependencies: AppDependencies
    let trackStore: TrackDataStore
    let snapshotService: SnapshotServiceSpy
}

@MainActor
func makeFixture(
    testArtists: [String],
    runRecordStore: (any RunRecordStore)? = nil
) throws -> LibraryPersistenceFixture {
    let trackStore = try TrackDataStore.createInMemory()
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
    private let claimError: (any Error)?
    private var storedRecord: RunRecord?
    private let reportPages: [RunReportPage]
    private let recoveryPage: RunReportPage?
    private var receivedReportQueries: [RunReportQuery] = []

    init(
        reportsError: (any Error)? = nil,
        recordError: (any Error)? = nil,
        claimError: (any Error)? = nil,
        storedRecord: RunRecord? = nil,
        reportPage: RunReportPage? = nil,
        reportPages: [RunReportPage]? = nil,
        recoveryPage: RunReportPage? = nil
    ) {
        self.reportsError = reportsError
        self.recordError = recordError
        self.claimError = claimError
        self.storedRecord = storedRecord
        self.reportPages = reportPages ?? reportPage.map { [$0] } ?? []
        self.recoveryPage = recoveryPage
    }

    func upsert(_ record: RunRecord) async throws {
        storedRecord = record
    }

    func loadAll() async throws -> [RunRecord] {
        storedRecord.map { [$0] } ?? []
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

    func recoveryRecords() async throws -> RunReportPage {
        if let reportsError {
            throw reportsError
        }
        if let recoveryPage {
            return recoveryPage
        }
        guard reportPages.count == 1, let page = reportPages.first else {
            return RunReportPage(records: [], skippedCorruptedCount: 0)
        }
        return page
    }

    func claimRecovery(for runID: RunID, id: UUID, at timestamp: Date) async throws -> UUID? {
        if let claimError {
            throw claimError
        }
        guard let record = storedRecord,
              record.runID == runID,
              record.finishedAt == nil,
              record.intent == .writeFixes,
              record.state.needsWriteRecovery
        else { return nil }
        if let recoveryID = record.recoveryID {
            return recoveryID
        }
        storedRecord = record.openingRecovery(id: id, at: timestamp)
        return id
    }

    func closeCorruptedRun(_: RunID, at _: Date) async throws -> Bool {
        false
    }

    func reports(matching query: RunReportQuery) async throws -> RunReportPage {
        receivedReportQueries.append(query)
        if let reportsError {
            throw reportsError
        }
        guard !reportPages.isEmpty else {
            return RunReportPage(records: [], skippedCorruptedCount: 0)
        }
        let page = reportPages[min(receivedReportQueries.count - 1, reportPages.count - 1)]
        return RunReportPage(
            records: page.records.filter { record in matches(record, query: query) },
            skippedCorruptedCount: page.skippedCorruptedCount,
            corruptedRunIDs: page.corruptedRunIDs,
            recoveryRunIDs: page.recoveryRunIDs
        )
    }

    func lastReportQuery() -> RunReportQuery? {
        receivedReportQueries.last
    }

    func reportQueries() -> [RunReportQuery] {
        receivedReportQueries
    }

    private func matches(_ record: RunRecord, query: RunReportQuery) -> Bool {
        if let startedAfter = query.startedAfter, record.startedAt < startedAfter {
            return false
        }
        if let startedBefore = query.startedBefore, record.startedAt > startedBefore {
            return false
        }
        if let states = query.states, !states.isEmpty, !states.contains(record.state) {
            return false
        }
        if let trigger = query.trigger, record.trigger != trigger {
            return false
        }
        return true
    }
}

func sampleRunRecord(
    runID: RunID = RunID(),
    intent: RunIntent = .observeLibrary,
    state: RunLifecycleState = .completed,
    recoveryID: UUID? = nil,
    failureMessage: String? = nil,
    finishedAt: Date? = Date(timeIntervalSince1970: 1_800_000_045)
) -> RunRecord {
    let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    return RunRecord(
        runID: runID,
        requestID: RunRequestID(),
        trigger: .manualCheck,
        intent: intent,
        scope: ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: nil,
            createdAt: startedAt,
            reason: "manualCheck"
        ),
        recoveryID: recoveryID,
        transitions: [RunLifecycleTransition(state: state, timestamp: startedAt)],
        syncSummary: nil,
        failureMessage: failureMessage,
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
        let candidate = currentURL.appendingPathComponent("App/Views/MainData.swift")
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
