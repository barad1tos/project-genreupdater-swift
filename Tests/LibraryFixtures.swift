import Core
import Foundation
@testable import Genre_Updater
@testable import Services

struct ContinuationsProbeFailure: Error {}

struct LibraryPersistenceFixture {
    let dependencies: AppDependencies
    let trackStore: TrackDataStore
    let snapshotService: SnapshotServiceSpy
}

actor MirrorTrackStoreStub: TrackStateStore {
    private var tracks: [Track]
    private var certificates: [ScopeCertificate]?
    private let certifiedArtists: [String]?
    private var revision = MirrorRevision.initial
    private let beforeLoad: (@Sendable () async throws -> Void)?

    init(
        tracks: [Track] = [],
        certifiedArtists: [String]? = nil,
        beforeLoad: (@Sendable () async throws -> Void)? = nil
    ) {
        self.tracks = tracks
        certificates = nil
        self.certifiedArtists = certifiedArtists
        self.beforeLoad = beforeLoad
    }

    func initialize() async throws {
        // This in-memory mirror stub requires no setup.
    }

    func loadAllTracks() async throws -> [Track] {
        try await beforeLoad?()
        return tracks
    }

    func loadMirrorSnapshot() async throws -> TrackMirrorSnapshot {
        try await beforeLoad?()
        let membership = try MembershipFingerprint.make(ids: tracks.compactMap(\.databaseID))
        let loadedCertificates: [ScopeCertificate] = if let certificates {
            certificates
        } else if let certifiedArtists {
            [ScopeCertificate(
                id: UUID(),
                revision: revision,
                membership: membership,
                testArtists: certifiedArtists,
                fieldSet: .processingV1,
                requestedFingerprint: "test-observation",
                observedFingerprint: "test-observation",
                trackCount: tracks.count,
                observedAt: Date()
            )]
        } else {
            []
        }
        return TrackMirrorSnapshot(
            revision: revision,
            membershipStamp: membership,
            presentIDs: Set(tracks.compactMap(\.databaseID)),
            presentTracks: tracks,
            repairCandidates: [],
            certificates: loadedCertificates
        )
    }

    @discardableResult
    func commitMirror(_ commit: MirrorCommit) async throws -> MirrorCommitResult {
        guard commit.baseRevision == revision else {
            throw MirrorRevisionConflict(expected: commit.baseRevision, actual: revision)
        }
        let nextRevision = try revision.advanced()
        tracks.append(contentsOf: commit.upserts)
        switch commit.certificates {
        case .preserve:
            break
        case let .replace(certificate), let .rebase(certificate):
            certificates = [certificate]
        case .invalidate:
            certificates = []
        }
        revision = nextRevision
        return MirrorCommitResult(revision: revision)
    }

    func getTrack(byID id: String) async throws -> Track? {
        tracks.first { $0.id == id }
    }

    func persistAppliedChange(_: ChangeLogEntry) async throws {
        // Library-load tests do not model applied-change persistence.
    }
    func getUnprocessedTracks() async throws -> [Track] {
        tracks
    }
    func trackCount() async throws -> Int {
        tracks.count
    }
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

@MainActor
func makeLibraryDependencies(
    trackStore: any TrackStateStore,
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

actor RunRecordStoreStub: RunRecordStore {
    private let reportsError: (any Error)?
    private let recordError: (any Error)?
    private let claimError: (any Error)?
    private var continuationsError: (any Error)?
    private var continuationRunIDs: [RunID] = []
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

    func reportItems(matching _: RunReportItemQuery) async throws -> RunReportItemPage {
        RunReportItemPage(items: [], skippedCorruptedCount: 0)
    }

    func resolvedRecoveryRun(recoveryID _: UUID) async throws -> RunID? {
        nil
    }

    func continuations(of _: RunID) async throws -> [RunID] {
        if let continuationsError {
            throw continuationsError
        }
        return continuationRunIDs
    }

    func installContinuations(_ runIDs: [RunID]) {
        continuationRunIDs = runIDs
    }

    func failContinuations() {
        continuationsError = ContinuationsProbeFailure()
    }

    func retainedPlanIDs() async throws -> Set<FixPlanID>? {
        []
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
            recoveryRunIDs: page.recoveryRunIDs,
            closableRunIDs: page.closableRunIDs,
            attentionRunIDs: page.attentionRunIDs,
            unsupportedRunIDs: page.unsupportedRunIDs
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
    let scope = ProcessingScopeSnapshot.capture(
        requestedTestArtists: [],
        knownTrackCount: nil,
        createdAt: startedAt,
        reason: "manualCheck"
    )
    let lifecycle = RunLifecycleSnapshot(
        runID: runID,
        requestID: RunRequestID(),
        trigger: .manualCheck,
        intent: intent,
        scope: scope,
        startedAt: startedAt,
        phase: .active(.created)
    )
    return RunRecord(
        lifecycle: lifecycle,
        transitions: [RunLifecycleTransition(state: state, timestamp: startedAt)],
        recoveryID: recoveryID,
        syncSummary: nil,
        failureMessage: failureMessage,
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

func libraryLoadChainSourceURL() throws -> URL {
    var currentURL = URL(fileURLWithPath: #filePath)
    currentURL.deleteLastPathComponent()

    for _ in 0 ..< 8 {
        let candidate = currentURL.appendingPathComponent("App/ViewModels/LibraryLoadChain.swift")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        currentURL.deleteLastPathComponent()
    }

    throw CocoaError(.fileNoSuchFile)
}

func libraryLoadSourceURL() throws -> URL {
    var currentURL = URL(fileURLWithPath: #filePath)
    currentURL.deleteLastPathComponent()

    for _ in 0 ..< 8 {
        let candidate = currentURL.appendingPathComponent("App/Views/DesignRootHostView.swift")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        currentURL.deleteLastPathComponent()
    }

    throw CocoaError(.fileNoSuchFile)
}

actor SnapshotServiceSpy: LibrarySnapshotService {
    var isEnabled = true
    private var saveSnapshotCallCount = 0
    private var savedTracks: [Track] = []

    private var seededSnapshot: [Track]?

    func installSnapshot(_ tracks: [Track]) {
        seededSnapshot = tracks
    }

    func loadSnapshot() async throws -> [Track]? {
        seededSnapshot
    }

    func saveSnapshot(_ tracks: [Track]) async throws -> String {
        saveSnapshotCallCount += 1
        savedTracks = tracks
        seededSnapshot = tracks
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

func canonicalMirrorTrack(_ track: Track) -> Track {
    var canonical = track
    canonical.appleScriptID = canonical.id
    return canonical
}
