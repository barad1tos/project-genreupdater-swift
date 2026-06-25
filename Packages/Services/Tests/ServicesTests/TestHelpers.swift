import Foundation
@testable import Core
@testable import Services

// MARK: - APIOrchestrator Test Factory

func makeAPIOrchestrator(
    musicBrainz: any ExternalAPIService,
    discogs: any ExternalAPIService,
    appleMusic: any ExternalAPIService,
    cache: (any CacheService)? = nil,
    disabledSources: Set<APISource> = [],
    configure: (inout APIOrchestratorConfiguration) -> Void = { _ in
        // Default test configuration needs no customization.
    }
) -> APIOrchestrator {
    var configuration = APIOrchestratorConfiguration()
    configuration.cache = cache
    configuration.disabledSources = disabledSources
    configure(&configuration)
    return APIOrchestrator(
        services: APIOrchestratorServices(
            musicBrainz: musicBrainz,
            discogs: discogs,
            appleMusic: appleMusic
        ),
        configuration: configuration
    )
}

extension ExternalAPIService {
    func getArtistActivityPeriod(normalizedArtist _: String) async throws -> (start: Int?, end: Int?) {
        (nil, nil)
    }

    func getArtistStartYear(normalizedArtist _: String) async throws -> Int? {
        nil
    }
}

// MARK: - MockAppleScriptClient

actor MockAppleScriptClient: AppleScriptClient {
    var writtenProperties: [(trackID: String, property: String, value: String)] = []
    var batchUpdates: [[(trackID: String, property: String, value: String)]] = []
    var trackIDsToFetch: [String] = []
    var tracksByID: [String: Track] = [:]
    var shouldThrow = false
    var shouldThrowBatch = false
    var shouldThrowBatchAfterMutation = false
    var shouldCancelBatch = false
    var shouldApplyBatchUpdates = true
    var shouldClearFetchedTracksAfterBatchUpdate = false
    var batchMutationLimit: Int?
    var singleWriteResult: AppleScriptWriteResult = .changed
    var customWriteError: Error?
    private var failingWriteTrackIDs: Set<String> = []
    private var fetchedTracksByIDsCalls: [(trackIDs: [String], batchSize: Int, timeout: Duration?)] = []
    private var fetchedAllTrackIDsTimeouts: [Duration?] = []

    func initialize() async throws {}

    func runScript(
        name _: String,
        arguments _: [String],
        timeout _: Duration?
    ) async throws -> String? {
        nil
    }

    func fetchTracksByIDs(
        _ trackIDs: [String],
        batchSize: Int,
        timeout: Duration?
    ) async throws -> [Track] {
        fetchedTracksByIDsCalls.append((trackIDs, batchSize, timeout))
        return trackIDs.compactMap { tracksByID[$0] }
    }

    func fetchAllTrackIDs(timeout: Duration?) async throws -> [String] {
        fetchedAllTrackIDsTimeouts.append(timeout)
        return trackIDsToFetch
    }

    func updateTrackProperty(
        trackID: String,
        property: String,
        value: String
    ) async throws -> AppleScriptWriteResult {
        if let customWriteError {
            throw customWriteError
        }
        if shouldThrow || failingWriteTrackIDs.contains(trackID) {
            throw MockScriptError.intentional
        }
        writtenProperties.append((trackID, property, value))
        if singleWriteResult == .changed {
            apply(property: property, value: value, toTrackWithID: trackID)
        }
        return singleWriteResult
    }

    func batchUpdateTracks(_ updates: [(trackID: String, property: String, value: String)]) async throws {
        batchUpdates.append(updates)
        if shouldCancelBatch {
            throw CancellationError()
        }
        if shouldThrowBatch {
            throw MockScriptError.intentional
        }
        guard shouldApplyBatchUpdates else { return }
        for update in updates.prefix(batchMutationLimit ?? updates.count) {
            apply(property: update.property, value: update.value, toTrackWithID: update.trackID)
        }
        if shouldThrowBatchAfterMutation {
            throw AppleScriptBatchVerificationError(
                updateCount: updates.count,
                failedCount: updates.count - (batchMutationLimit ?? updates.count),
                reason: "test verification failure"
            )
        }
        if shouldClearFetchedTracksAfterBatchUpdate {
            tracksByID.removeAll()
        }
    }

    func setThrowMode(_ shouldFail: Bool) {
        shouldThrow = shouldFail
    }

    func setBatchThrowMode(_ shouldFail: Bool) {
        shouldThrowBatch = shouldFail
    }

    func setBatchPostRunVerificationFailureMode(_ shouldFail: Bool) {
        shouldThrowBatchAfterMutation = shouldFail
    }

    func setBatchCancellationMode(_ shouldCancel: Bool) {
        shouldCancelBatch = shouldCancel
    }

    func setBatchMutationEnabled(_ isEnabled: Bool) {
        shouldApplyBatchUpdates = isEnabled
    }

    func setFetchedTracksClearedAfterBatchUpdate(_ isEnabled: Bool) {
        shouldClearFetchedTracksAfterBatchUpdate = isEnabled
    }

    func setBatchMutationLimit(_ limit: Int?) {
        batchMutationLimit = limit
    }

    func setSingleWriteResult(_ result: AppleScriptWriteResult) {
        singleWriteResult = result
    }

    func setCustomWriteError(_ error: Error?) {
        customWriteError = error
    }

    func setFailingWriteTrackIDs(_ trackIDs: Set<String>) {
        failingWriteTrackIDs = trackIDs
    }

    func setFetchedTracks(_ tracks: [Track]) {
        trackIDsToFetch = tracks.map(\.id)
        tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
    }

    func fetchTracksByIDsCalls() -> [(trackIDs: [String], batchSize: Int, timeout: Duration?)] {
        fetchedTracksByIDsCalls
    }

    func fetchAllTrackIDsTimeouts() -> [Duration?] {
        fetchedAllTrackIDsTimeouts
    }

    private func apply(property: String, value: String, toTrackWithID trackID: String) {
        guard var track = tracksByID[trackID] else { return }

        switch property {
        case "genre":
            track.genre = value
        case "year":
            track.year = Int(value)
        case "name":
            track.name = value
        case "album":
            track.album = value
        case "artist":
            track.artist = value
        default:
            return
        }
        tracksByID[trackID] = track
    }
}

// MARK: - MockScriptError

enum MockScriptError: Error {
    case intentional
}

// MARK: - MockTrackStore

actor MockTrackStore: TrackStateStore {
    var tracks: [Track] = []

    func initialize() async throws {}

    func loadAllTracks() async throws -> [Track] {
        tracks
    }

    func saveTracks(_ newTracks: [Track]) async throws {
        tracks = newTracks
    }

    func deleteTrackIDs(_ ids: [String]) async throws -> Int {
        let idsToDelete = Set(ids)
        let originalCount = tracks.count
        tracks.removeAll { idsToDelete.contains($0.id) }
        return originalCount - tracks.count
    }

    func getTrack(byID id: String) async throws -> Track? {
        tracks.first { $0.id == id }
    }

    func updateTrackProcessingState(
        id _: String,
        genreUpdated _: Bool?,
        yearUpdated _: Bool?
    ) async throws {}

    func getUnprocessedTracks() async throws -> [Track] {
        tracks
    }

    func trackCount() async throws -> Int {
        tracks.count
    }
}

// MARK: - MockCacheService

actor MockCacheService: CacheService {
    var albumYears: [String: AlbumCacheEntry] = [:]
    var apiResults: [String: CachedAPIResult] = [:]
    private var genericEntries: [String: MockGenericCacheEntry] = [:]

    func initialize() async throws {}
    func get<T: Codable & Sendable>(key: String) async -> T? {
        guard let entry = genericEntries[key], !entry.isExpired else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: entry.data)
    }

    func set(key: String, value: some Codable & Sendable, ttl: TimeInterval?) async {
        guard let data = try? JSONEncoder().encode(value) else { return }
        genericEntries[key] = MockGenericCacheEntry(data: data, timestamp: .now, ttl: ttl)
    }

    func setRawJSON(key: String, json: String, ttl: TimeInterval?) async {
        genericEntries[key] = MockGenericCacheEntry(data: Data(json.utf8), timestamp: .now, ttl: ttl)
    }

    func invalidate(key: String) async {
        genericEntries.removeValue(forKey: key)
    }

    func clear() async {
        genericEntries.removeAll()
        albumYears.removeAll()
        apiResults.removeAll()
    }

    func getAlbumYear(artist: String, album: String) async -> AlbumCacheEntry? {
        albumYears[albumYearKey(artist: artist, album: album)]
    }

    func storeAlbumYear(artist: String, album: String, year: Int, confidence: Int) async {
        albumYears[albumYearKey(artist: artist, album: album)] = AlbumCacheEntry(
            artist: artist,
            album: album,
            year: year,
            confidence: confidence,
            timestamp: Date()
        )
    }

    func invalidateAlbum(artist: String, album: String) async {
        albumYears.removeValue(forKey: albumYearKey(artist: artist, album: album))
    }

    func invalidateAllAlbumYears() async {
        albumYears.removeAll()
    }

    func getCachedAPIResult(artist: String, album: String, source: String) async -> CachedAPIResult? {
        apiResults[apiResultKey(artist: artist, album: album, source: source)]
    }

    func setCachedAPIResult(_ result: CachedAPIResult) async {
        apiResults[apiResultKey(artist: result.artist, album: result.album, source: result.source)] = result
    }

    func invalidateCachedAPIResults(artist: String, album: String) async {
        let keyPrefix = "\(normalizeForMatching(artist))-\(normalizeForMatching(album))-"
        apiResults = apiResults.filter { key, _ in
            !key.hasPrefix(keyPrefix)
        }
    }

    func syncToDisk() async throws {}

    private func albumYearKey(artist: String, album: String) -> String {
        "\(normalizeForMatching(artist))-\(normalizeForMatching(album))"
    }

    private func apiResultKey(artist: String, album: String, source: String) -> String {
        "\(normalizeForMatching(artist))-\(normalizeForMatching(album))-\(normalizeForMatching(source))"
    }
}

// MARK: - MockUndoLibrarySnapshotService

actor MockUndoLibrarySnapshotService: LibrarySnapshotService {
    private var didClearSnapshot = false
    private var snapshotMetadata: LibraryCacheMetadata?
    private var deltaCache: LibraryDeltaCache?
    private let isSnapshotCachingEnabled: Bool
    private let isSnapshotDeltaCachingEnabled: Bool

    init(
        isSnapshotCachingEnabled: Bool = true,
        isSnapshotDeltaCachingEnabled: Bool = true
    ) {
        self.isSnapshotCachingEnabled = isSnapshotCachingEnabled
        self.isSnapshotDeltaCachingEnabled = isSnapshotDeltaCachingEnabled
    }

    var isEnabled: Bool {
        isSnapshotCachingEnabled
    }

    var isDeltaEnabled: Bool {
        isSnapshotDeltaCachingEnabled
    }

    func loadSnapshot() async throws -> [Track]? {
        nil
    }

    func saveSnapshot(_: [Track]) async throws -> String {
        "snapshot"
    }

    func clearSnapshot() async {
        didClearSnapshot = true
    }

    func isSnapshotValid() async -> Bool {
        false
    }

    func getSnapshotMetadata() async -> LibraryCacheMetadata? {
        snapshotMetadata
    }

    func updateSnapshotMetadata(_ metadata: LibraryCacheMetadata) async throws {
        snapshotMetadata = metadata
    }

    func loadDelta() async -> LibraryDeltaCache? {
        deltaCache
    }

    func saveDelta(_ delta: LibraryDeltaCache) async throws {
        deltaCache = delta
    }

    func getLibraryModificationDate() async throws -> Date {
        .now
    }

    func wasCleared() async -> Bool {
        didClearSnapshot
    }
}

private struct MockGenericCacheEntry {
    let data: Data
    let timestamp: Date
    let ttl: TimeInterval?

    var isExpired: Bool {
        guard let ttl else { return false }
        return Date.now > timestamp.addingTimeInterval(ttl)
    }
}

// MARK: - MockAPIService

/// Mock `ExternalAPIService` for testing orchestration logic.
///
/// Returns a preconfigured `YearResult`, optionally throwing or delaying
/// to simulate network failures and slow responses.
struct MockAPIService: ExternalAPIService {
    let yearResult: YearResult
    let releaseCandidates: [ReleaseCandidate]
    let shouldThrow: Bool
    let delay: Duration
    let artistActivityPeriod: (start: Int?, end: Int?)
    let artistStartYear: Int?

    init(
        yearResult: YearResult = YearResult(),
        releaseCandidates: [ReleaseCandidate] = [],
        shouldThrow: Bool = false,
        delay: Duration = .zero,
        artistActivityPeriod: (start: Int?, end: Int?) = (nil, nil),
        artistStartYear: Int? = nil
    ) {
        self.yearResult = yearResult
        self.releaseCandidates = releaseCandidates
        self.shouldThrow = shouldThrow
        self.delay = delay
        self.artistActivityPeriod = artistActivityPeriod
        self.artistStartYear = artistStartYear
    }

    func getAlbumYear(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        try await waitIfNeeded()
        if shouldThrow {
            throw MockAPIError.intentional
        }
        return yearResult
    }

    func getReleaseCandidates(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> [ReleaseCandidate] {
        try await waitIfNeeded()
        if shouldThrow {
            throw MockAPIError.intentional
        }
        return releaseCandidates
    }

    func getArtistActivityPeriod(
        normalizedArtist _: String
    ) async throws -> (start: Int?, end: Int?) {
        if shouldThrow {
            throw MockAPIError.intentional
        }
        return artistActivityPeriod
    }

    func getArtistStartYear(
        normalizedArtist _: String
    ) async throws -> Int? {
        if shouldThrow {
            throw MockAPIError.intentional
        }
        return artistStartYear
    }

    func initialize(force _: Bool) async throws {
        try Task.checkCancellation()
    }

    private func waitIfNeeded() async throws {
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
    }
}

// MARK: - MockAPIError

enum MockAPIError: Error {
    case intentional
}
