import Core
import Foundation
import Services

extension TrackStateStore {
    func seedMirror(_ tracks: [Track]) async throws {
        let revision = try await loadMirrorSnapshot().revision
        let canonicalTracks = tracks.map { track in
            var canonical = track
            canonical.appleScriptID = canonical.id
            return canonical
        }
        try await applyMirror(TrackMirrorUpdate(
            baseRevision: revision,
            coverageChange: .replace(.fullLibrary),
            repairs: [],
            upserts: canonicalTracks,
            deletions: []
        ))
    }
}

func testMusicDatabaseID(_ rawValue: String) -> MusicDatabaseTrackID {
    guard let databaseID = MusicDatabaseTrackID(rawValue: rawValue) else {
        preconditionFailure("Invalid test database ID: \(rawValue)")
    }
    return databaseID
}

struct DashboardStateAPIService: ExternalAPIService {
    let year: Int?
    let confidence: Int
    let isDefinitive: Bool
    let isLookupAvailable: Bool
    let beforeAlbumYearLookup: (@Sendable () async -> Void)?

    init(
        year: Int? = nil,
        confidence: Int = 0,
        isDefinitive: Bool = true,
        isLookupAvailable: Bool = true,
        beforeAlbumYearLookup: (@Sendable () async -> Void)? = nil
    ) {
        self.year = year
        self.confidence = confidence
        self.isDefinitive = isDefinitive
        self.isLookupAvailable = isLookupAvailable
        self.beforeAlbumYearLookup = beforeAlbumYearLookup
    }

    func getAlbumYear(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        await beforeAlbumYearLookup?()
        guard isLookupAvailable else {
            throw LookupFixtureError.unavailable
        }
        return YearResult(
            year: year,
            isDefinitive: isDefinitive,
            confidence: confidence,
            yearScores: year.map { [$0: confidence] } ?? [:]
        )
    }

    func getReleaseCandidates(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> [ReleaseCandidate] {
        []
    }

    func getArtistActivityPeriod(normalizedArtist _: String) async throws -> (start: Int?, end: Int?) {
        (nil, nil)
    }

    func getArtistStartYear(normalizedArtist _: String) async throws -> Int? {
        nil
    }

    func initialize(force _: Bool) async throws {
        // Test double has no external resources to initialize.
    }

    func close() async {
        // Test double has no external resources to release.
    }
}

private enum LookupFixtureError: Error {
    case unavailable
}

actor DashboardStateScriptClient: MusicAppMutating, MusicAppVerifying {
    private let failingTrackIDs: Set<String>
    private let cancellingTrackIDs: Set<String>
    private let outcomeTrackIDs: Set<String>
    private let noChangeTrackIDs: Set<String>
    private let writeHold: LiveBatchHold?
    private let metadataByID: [String: Track]?
    private var writes: [MusicTrackUpdate] = []

    init(
        failingTrackIDs: Set<String> = [],
        cancellingTrackIDs: Set<String> = [],
        outcomeTrackIDs: Set<String> = [],
        noChangeTrackIDs: Set<String> = [],
        verifiedTracks: [Track]? = nil,
        writeHold: LiveBatchHold? = nil
    ) {
        self.failingTrackIDs = failingTrackIDs
        self.cancellingTrackIDs = cancellingTrackIDs
        self.outcomeTrackIDs = outcomeTrackIDs
        self.noChangeTrackIDs = noChangeTrackIDs
        metadataByID = verifiedTracks.map { tracks in
            Dictionary(uniqueKeysWithValues: tracks.map { track in
                (track.databaseID?.rawValue ?? track.id, track)
            })
        }
        self.writeHold = writeHold
    }

    func fetchMetadata(for databaseIDs: [MusicDatabaseTrackID]) async throws -> [Track] {
        if let metadataByID {
            return databaseIDs.compactMap { metadataByID[$0.rawValue] }
        }
        return databaseIDs.map { databaseID in
            Track(
                id: databaseID.rawValue,
                name: "Track \(databaseID.rawValue)",
                artist: "Artist",
                album: "Album",
                trackStatus: TrackKind.subscription.rawValue,
                appleScriptID: databaseID.rawValue
            )
        }
    }

    func update(
        _ update: MusicTrackUpdate,
        onAttempt: @escaping WriteAttemptHook
    ) async throws -> MusicWriteResult {
        let databaseID = update.databaseID.rawValue
        if let writeHold {
            await writeHold.holdOnce()
            try Task.checkCancellation()
        }
        if cancellingTrackIDs.contains(databaseID) {
            throw CancellationError()
        }
        if outcomeTrackIDs.contains(databaseID) {
            try await onAttempt()
            throw AppleScriptOutcomeError(scriptName: "update_property", duration: .seconds(3))
        }
        if failingTrackIDs.contains(databaseID) {
            throw DashboardStateScriptWriteError(trackID: databaseID)
        }
        writes.append(update)
        try await onAttempt()
        if noChangeTrackIDs.contains(databaseID) {
            return .noChange
        }
        return .changed
    }

    func update(
        _ updates: [MusicTrackUpdate],
        onAttempt: @escaping WriteAttemptHook
    ) async throws {
        guard !updates.isEmpty else { return }
        var hasAttempted = false
        do {
            for update in updates {
                let databaseID = update.databaseID.rawValue
                if cancellingTrackIDs.contains(databaseID) {
                    throw CancellationError()
                }
                if outcomeTrackIDs.contains(databaseID) {
                    throw AppleScriptOutcomeError(scriptName: "batch_update_tracks", duration: .seconds(3))
                }
                if failingTrackIDs.contains(databaseID) {
                    throw DashboardStateScriptWriteError(trackID: databaseID)
                }
                writes.append(update)
                hasAttempted = true
            }
        } catch let error as AppleScriptOutcomeError {
            try await onAttempt()
            throw error
        } catch {
            if hasAttempted {
                try await onAttempt()
            }
            throw error
        }
        try await onAttempt()
    }

    func updatedProperties() -> [MusicTrackUpdate] {
        writes
    }
}

private struct DashboardStateScriptWriteError: LocalizedError {
    let trackID: String

    var errorDescription: String? {
        "script write failed for \(trackID)"
    }
}

actor DashboardStateTrackStore: TrackStateStore {
    func initialize() async throws {
        // Test double has no external resources to initialize.
    }

    func loadAllTracks() async throws -> [Track] {
        []
    }

    func loadMirrorSnapshot() async throws -> TrackMirrorSnapshot {
        TrackMirrorSnapshot(revision: .initial, tracks: [], coverage: .unknown)
    }

    @discardableResult
    func applyMirror(_ update: TrackMirrorUpdate) async throws -> MirrorRevision {
        // These tests do not assert persisted track state.
        update.baseRevision.advanced()
    }

    func getTrack(byID _: String) async throws -> Track? {
        nil
    }

    func persistAppliedChange(_: ChangeLogEntry) async throws {
        // These tests do not assert applied track persistence.
    }

    func getUnprocessedTracks() async throws -> [Track] {
        []
    }

    func trackCount() async throws -> Int {
        0
    }
}

actor DashboardStateCacheService: CacheService {
    func initialize() async throws {
        // Test double has no external resources to initialize.
    }

    func get<T: Codable & Sendable>(key _: String) async -> T? {
        nil
    }

    func set(key _: String, value _: some Codable & Sendable, ttl _: TimeInterval?) async {
        // These tests do not assert generic cache writes.
    }

    func invalidate(key _: String) async {
        // These tests do not assert generic cache invalidation.
    }

    func clear() async {
        // These tests do not assert cache clearing.
    }

    func getAlbumYear(artist _: String, album _: String) async -> AlbumCacheEntry? {
        nil
    }

    func storeAlbumYear(artist _: String, album _: String, year _: Int, confidence _: Int) async {
        // These tests read album-year results from the API service stub.
    }

    func invalidateAlbum(artist _: String, album _: String) async {
        // These tests do not assert album cache invalidation.
    }

    func invalidateAllAlbumYears() async {
        // These tests do not assert album cache invalidation.
    }

    func getCachedAPIResult(artist _: String, album _: String, source _: String) async -> CachedAPIResult? {
        nil
    }

    func setCachedAPIResult(_: CachedAPIResult) async {
        // These tests do not assert API-result cache writes.
    }

    func invalidateCachedAPIResults(artist _: String, album _: String) async {
        // These tests do not assert API-result cache invalidation.
    }

    func syncToDisk() async throws {
        // Test double has no disk-backed cache to synchronize.
    }
}
