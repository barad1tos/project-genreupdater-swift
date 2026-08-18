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

// MARK: - MockTrackStore

struct AppliedTrackUpdate {
    let id: String
    let genreUpdated: Bool?
    let yearUpdated: Bool?
}

actor MockTrackStore: TrackStateStore {
    var tracks: [Track] = []
    private(set) var appliedUpdates: [AppliedTrackUpdate] = []
    private var shouldCancelReads = false
    private var shouldFailMirror = false
    private var appliedUpdateHook: (@Sendable () throws -> Void)?

    func failAppliedUpdates() {
        shouldFailMirror = true
    }

    func resumeAppliedUpdates() {
        shouldFailMirror = false
    }

    func setReadCancellation(_ isEnabled: Bool) {
        shouldCancelReads = isEnabled
    }

    func setAppliedUpdateHook(_ hook: (@Sendable () throws -> Void)?) {
        appliedUpdateHook = hook
    }

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
        if shouldCancelReads {
            throw CancellationError()
        }
        return tracks.first { $0.id == id }
    }

    func persistAppliedChange(_ change: ChangeLogEntry) async throws {
        if shouldFailMirror {
            throw MockScriptError.intentional
        }
        if let index = tracks.firstIndex(where: { $0.id == change.trackID }) {
            tracks[index] = try tracks[index].applying(change)
        }
        appliedUpdates.append(AppliedTrackUpdate(
            id: change.trackID,
            genreUpdated: change.changeType == .genreUpdate ? true : nil,
            yearUpdated: change.changeType == .yearUpdate || change.changeType == .yearRevert ? true : nil
        ))
        try appliedUpdateHook?()
    }

    func getUnprocessedTracks() async throws -> [Track] {
        tracks
    }

    func trackCount() async throws -> Int {
        tracks.count
    }
}

// MARK: - MockChangeLogStore

actor MockChangeLogStore: ChangeLogStore {
    private(set) var entries: [ChangeLogEntry] = []
    private var shouldCancelNextLoad = false
    private var shouldFailDeletes = false
    private var shouldFailLoads = false
    private var shouldFailSaves = false

    func failDeletes() {
        shouldFailDeletes = true
    }

    func resumeDeletes() {
        shouldFailDeletes = false
    }

    func failLoads() {
        shouldFailLoads = true
    }

    func cancelNextLoad() {
        shouldCancelNextLoad = true
    }

    func failSaves() {
        shouldFailSaves = true
    }

    func resumeSaves() {
        shouldFailSaves = false
    }

    func loadRecent(limit: Int) async throws -> [ChangeLogEntry] {
        Array(entries.sorted { $0.timestamp > $1.timestamp }.prefix(limit))
    }

    func saveEntry(_ entry: ChangeLogEntry) async throws {
        if shouldFailSaves {
            throw MockScriptError.intentional
        }
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
    }

    func saveEntries(_ entries: [ChangeLogEntry]) async throws {
        if shouldFailSaves {
            throw MockScriptError.intentional
        }
        let entryIDs = Set(entries.map(\.id))
        self.entries.removeAll { entryIDs.contains($0.id) }
        self.entries.append(contentsOf: entries)
    }

    func loadAll() async throws -> [ChangeLogEntry] {
        if shouldCancelNextLoad {
            shouldCancelNextLoad = false
            throw CancellationError()
        }
        if shouldFailLoads {
            throw MockScriptError.intentional
        }
        return entries
    }

    func delete(entryID: UUID) async throws {
        if shouldFailDeletes {
            throw MockScriptError.intentional
        }
        entries.removeAll { $0.id == entryID }
    }

    func deleteAll() async throws {
        entries.removeAll()
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
    private let isSnapshotCachingEnabled: Bool

    init(isSnapshotCachingEnabled: Bool = true) {
        self.isSnapshotCachingEnabled = isSnapshotCachingEnabled
    }

    var isEnabled: Bool {
        isSnapshotCachingEnabled
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
    let artistRegion: String?

    init(
        yearResult: YearResult = YearResult(),
        releaseCandidates: [ReleaseCandidate] = [],
        shouldThrow: Bool = false,
        delay: Duration = .zero,
        artistActivityPeriod: (start: Int?, end: Int?) = (nil, nil),
        artistStartYear: Int? = nil,
        artistRegion: String? = nil
    ) {
        self.yearResult = yearResult
        self.releaseCandidates = releaseCandidates
        self.shouldThrow = shouldThrow
        self.delay = delay
        self.artistActivityPeriod = artistActivityPeriod
        self.artistStartYear = artistStartYear
        self.artistRegion = artistRegion
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

    func getArtistRegion(artist _: String) async throws -> String? {
        if shouldThrow {
            throw MockAPIError.intentional
        }
        return artistRegion
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

// MARK: - EventCounter

// Safety: the lock protects the observed count; AsyncStream owns waiter cancellation.
final class EventCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let stream: AsyncStream<Int>
    private let continuation: AsyncStream<Int>.Continuation
    private var count = 0

    init() {
        (stream, continuation) = AsyncStream.makeStream(
            of: Int.self,
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    deinit {
        continuation.finish()
    }

    func record() {
        let observedCount = lock.withLock {
            count += 1
            return count
        }
        continuation.yield(observedCount)
    }

    func wait(for expectedCount: Int, timeout: Duration = .seconds(60)) async -> Bool {
        guard lock.withLock({ count }) < expectedCount else { return true }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { [stream] in
                for await observedCount in stream where observedCount >= expectedCount {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }

            let didObserveEvent = await group.next() ?? false
            group.cancelAll()
            return didObserveEvent
        }
    }
}

struct TaskWaitTimeout: Error {}

func taskValue<Value: Sendable>(
    _ task: Task<Value, any Error>,
    timeout: Duration = .seconds(60)
) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
        let race = TaskValueRace(continuation)
        Task {
            await race.resolve(task.result)
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            race.resolve(.failure(TaskWaitTimeout()), cancelling: task)
        }
        race.installTimeout(timeoutTask)
    }
}

// Safety: the lock serializes the one-shot continuation and timeout-task state.
private final class TaskValueRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var timeoutTask: Task<Void, Never>?
    private var isResolved = false

    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = continuation
    }

    func installTimeout(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock {
            guard !isResolved else { return true }
            timeoutTask = task
            return false
        }
        if shouldCancel {
            task.cancel()
        }
    }

    @discardableResult
    func resolve(
        _ result: Result<Value, any Error>,
        cancelling task: Task<Value, any Error>? = nil
    ) -> Bool {
        let resolution: (CheckedContinuation<Value, any Error>?, Task<Void, Never>?)? = lock.withLock {
            guard !isResolved else { return nil }
            isResolved = true
            let resolution = (continuation, timeoutTask)
            continuation = nil
            timeoutTask = nil
            return resolution
        }
        guard let (continuation, timeoutTask) = resolution else { return false }

        task?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(with: result)
        return true
    }
}
