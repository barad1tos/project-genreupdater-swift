import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

struct RandomAccessPendingFixture {
    let service: WorkflowPendingVerificationService
}

struct RandomAccessPendingRun {
    let pendingFixture: RandomAccessPendingFixture
    let viewModel: WorkflowViewModel
}

struct RandomAccessLiveBatchRun {
    let fixture: WorkflowFixture
    let viewModel: WorkflowViewModel
    let pendingVerification: WorkflowPendingVerificationService
    let batchTracks: [Track]
    let timestampUpdates: PendingTimestampUpdateCounter
}

struct RandomAccessWorkflowFixtureOptions {
    var apiService = DashboardStateAPIService(year: 2013, confidence: 100)
    var randomAccessYear: Int?
    var failingWriteTrackIDs: Set<String> = []
    var cancellingWriteTrackIDs: Set<String> = []
    var additionalEnrichedTracks: [Track] = []
    var additionalAppleScriptIDsByMusicKitID: [String: String] = [:]
    var idMapper: (any TrackIDMapping)?
    var resolveIncrementalTracks: ([Track], IncrementalTrackScopeOptions) async -> [Track] = { tracks, _ in tracks }
    var runMaintenancePreflight: (() async -> MaintenancePreflightResult?)?
    var ensureRecoveryHold: () async -> Bool = { false }
    var prepareMutationMetadata: (([Track]) async throws -> Void)? = noOpPrepareMutationMetadata
    var updateIncrementalRunTimestamp: (() async -> Void)?
}

enum PendingPreflightState {
    case due
    case notDue
    case unavailable

    var result: MaintenancePreflightResult? {
        switch self {
        case .due:
            MaintenancePreflightResult(
                databaseVerification: nil,
                databaseVerificationError: nil,
                isPendingVerificationDue: true
            )
        case .notDue:
            MaintenancePreflightResult(
                databaseVerification: nil,
                databaseVerificationError: nil,
                isPendingVerificationDue: false
            )
        case .unavailable:
            nil
        }
    }
}

func expectPendingSummary(
    _ summary: UpdateRunPendingVerificationSummary,
    total: Int,
    due: Int,
    problematic: Int
) {
    #expect(summary.total == total)
    #expect(summary.due == due)
    #expect(summary.problematic == problematic)
}

@MainActor
func makeRandomAccessPendingViewModel(
    pendingSnapshotDelay: PendingSnapshotDelay? = nil
) -> RandomAccessPendingRun {
    let pendingFixture = makeRandomAccessPendingFixture(
        pendingSnapshotDelay: pendingSnapshotDelay
    )
    let fixture = makeRandomAccessWorkflowFixture(
        pendingVerificationService: pendingFixture.service
    )
    let viewModel = fixture.viewModel
    viewModel.mode = .pendingVerification
    return RandomAccessPendingRun(pendingFixture: pendingFixture, viewModel: viewModel)
}

@MainActor
func makeRandomAccessLiveBatchRun(
    pendingVerificationService: WorkflowPendingVerificationService? = nil,
    randomAccessYear: Int? = nil,
    failingWriteTrackIDs: Set<String> = [],
    cancellingWriteTrackIDs: Set<String> = [],
    preflightState: PendingPreflightState = .due
) -> RandomAccessLiveBatchRun {
    let batchTracks = [batchYearTrack()]
    let batchTrackIDs = Set(batchTracks.map(\.id))
    let scriptIDsByMusicKitID = Dictionary(
        uniqueKeysWithValues: batchTracks.map { ($0.id, "as-\($0.id)") }
    )
    let timestampUpdates = PendingTimestampUpdateCounter()
    let pendingVerification = pendingVerificationService ?? WorkflowPendingVerificationService(
        entries: [randomAccessMemoriesPendingEntry()],
        dueEntries: [randomAccessMemoriesPendingEntry()]
    )
    var options = RandomAccessWorkflowFixtureOptions()
    options.apiService = DashboardStateAPIService(year: 2013, confidence: 100)
    options.randomAccessYear = randomAccessYear
    options.failingWriteTrackIDs = failingWriteTrackIDs
    options.cancellingWriteTrackIDs = cancellingWriteTrackIDs
    options.additionalEnrichedTracks = batchTracks
    options.additionalAppleScriptIDsByMusicKitID = scriptIDsByMusicKitID
    options.resolveIncrementalTracks = { tracks, _ in
        tracks.filter { batchTrackIDs.contains($0.id) }
    }
    options.runMaintenancePreflight = { preflightState.result }
    options.prepareMutationMetadata = noOpPrepareMutationMetadata
    options.updateIncrementalRunTimestamp = {
        await timestampUpdates.record()
    }
    let fixture = makeRandomAccessWorkflowFixture(
        pendingVerificationService: pendingVerification,
        options: options
    )
    let viewModel = fixture.viewModel
    viewModel.mode = .fullLibrary
    viewModel.previewOnly = false
    viewModel.updateGenre = false
    viewModel.updateYear = true
    return RandomAccessLiveBatchRun(
        fixture: fixture,
        viewModel: viewModel,
        pendingVerification: pendingVerification,
        batchTracks: batchTracks,
        timestampUpdates: timestampUpdates
    )
}

@MainActor
func startRandomAccessLiveYearBatch(
    _ run: RandomAccessLiveBatchRun,
    randomAccessYear: Int? = nil
) {
    run.viewModel.start(
        tracks: randomAccessMemoriesMusicKitTracks(year: randomAccessYear) + run.batchTracks
    )
}

@MainActor
func makeRandomAccessWorkflowFixture(
    pendingVerificationService: WorkflowPendingVerificationService,
    configure: (inout RandomAccessWorkflowFixtureOptions) -> Void
) -> WorkflowFixture {
    var options = RandomAccessWorkflowFixtureOptions()
    configure(&options)
    return makeRandomAccessWorkflowFixture(
        pendingVerificationService: pendingVerificationService,
        options: options
    )
}

@MainActor
func makeRandomAccessWorkflowFixture(
    pendingVerificationService: WorkflowPendingVerificationService,
    options: RandomAccessWorkflowFixtureOptions = RandomAccessWorkflowFixtureOptions()
) -> WorkflowFixture {
    let resolvedIDMapper = options.idMapper ?? WorkflowTrackIDMapper(
        enrichedTracks: randomAccessMemoriesTracksWithAlbumArtist(year: options.randomAccessYear)
            + options.additionalEnrichedTracks,
        appleScriptIDsByMusicKitID: [
            "ram-1": "as-ram-1",
            "ram-2": "as-ram-2",
        ].merging(options.additionalAppleScriptIDsByMusicKitID) { current, _ in current }
    )

    return makeWorkflowFixture(
        apiService: options.apiService,
        failingWriteTrackIDs: options.failingWriteTrackIDs,
        resolveIncrementalTracks: options.resolveIncrementalTracks,
        pendingVerificationService: pendingVerificationService,
        idMapper: resolvedIDMapper,
        prepareMutationMetadata: options.prepareMutationMetadata
    ) { fixtureOptions in
        fixtureOptions.cancellingWriteTrackIDs = options.cancellingWriteTrackIDs
        fixtureOptions.runMaintenancePreflight = options.runMaintenancePreflight
        fixtureOptions.ensureRecoveryHold = options.ensureRecoveryHold
        fixtureOptions.updateIncrementalRunTimestamp = options.updateIncrementalRunTimestamp
    }
}

func makeRandomAccessPendingFixture(
    pendingSnapshotDelay: PendingSnapshotDelay? = nil
) -> RandomAccessPendingFixture {
    let resolvedEntry = randomAccessMemoriesPendingEntry()
    let skippedEntry = pureRockFuryPendingEntry()
    let service = WorkflowPendingVerificationService(
        entries: [resolvedEntry, skippedEntry],
        dueEntries: [resolvedEntry],
        problematicAlbums: [problematicPendingAlbum(entry: resolvedEntry)],
        pendingSnapshotDelay: pendingSnapshotDelay
    )
    return RandomAccessPendingFixture(service: service)
}

func randomAccessMemoriesPendingEntry() -> PendingAlbumEntry {
    pendingEntry(
        id: "daft-punk-random-access-memories",
        artist: "Daft Punk",
        album: "Random Access Memories"
    )
}

func pureRockFuryPendingEntry() -> PendingAlbumEntry {
    pendingEntry(
        id: "clutch-pure-rock-fury",
        artist: "Clutch",
        album: "Pure Rock Fury"
    )
}

func noisePendingEntry() -> PendingAlbumEntry {
    pendingEntry(id: "archive-noise", artist: "Archive", album: "Noise")
}

func batchYearTrack(id: String = "batch-year") -> Track {
    Track(
        id: id,
        name: "Batch Year",
        artist: "Clutch",
        album: "Pure Rock Fury",
        year: 1999
    )
}

func pendingEntry(id: String, artist: String, album: String) -> PendingAlbumEntry {
    PendingAlbumEntry(
        id: id,
        artist: artist,
        album: album,
        reason: "no_year_found"
    )
}

func problematicPendingAlbum(
    entry: PendingAlbumEntry,
    attempts: Int = 3,
    daysSinceFirstAttempt: Int = 14
) -> ProblematicPendingAlbum {
    let attemptDate = Date(timeIntervalSince1970: 1_700_000_000)
    return ProblematicPendingAlbum(
        entry: entry,
        totalAttempts: attempts,
        firstAttempt: attemptDate,
        lastAttempt: attemptDate,
        daysSinceFirstAttempt: daysSinceFirstAttempt
    )
}

func pendingDuePreflight() -> MaintenancePreflightResult {
    MaintenancePreflightResult(
        databaseVerification: nil,
        databaseVerificationError: nil,
        isPendingVerificationDue: true
    )
}

func staleDatabaseVerificationPreflight() -> MaintenancePreflightResult {
    MaintenancePreflightResult(
        databaseVerification: DatabaseVerificationResult(
            verifiedTrackCount: 42,
            removedTrackIDs: ["stale-track-id"]
        ),
        databaseVerificationError: nil,
        isPendingVerificationDue: false
    )
}

actor PendingTimestampUpdateCounter {
    private var updates = 0

    func record() {
        updates += 1
    }

    func count() -> Int {
        updates
    }
}

actor LiveBatchHold {
    private let holdOnCall: Int
    private var callCount = 0
    private var hasHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(holdOnCall: Int = 1) {
        self.holdOnCall = holdOnCall
    }

    func holdOnce() async {
        callCount += 1
        guard callCount == holdOnCall, !hasHeld else { return }
        hasHeld = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilHeld() async {
        guard !hasHeld else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
