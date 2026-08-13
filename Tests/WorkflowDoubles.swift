import Core
import Foundation
import Services

struct DashboardStateAPIService: ExternalAPIService {
    let year: Int?
    let confidence: Int
    let isDefinitive: Bool
    let beforeAlbumYearLookup: (@Sendable () async -> Void)?

    init(
        year: Int? = nil,
        confidence: Int = 0,
        isDefinitive: Bool = true,
        beforeAlbumYearLookup: (@Sendable () async -> Void)? = nil
    ) {
        self.year = year
        self.confidence = confidence
        self.isDefinitive = isDefinitive
        self.beforeAlbumYearLookup = beforeAlbumYearLookup
    }

    func getAlbumYear(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        await beforeAlbumYearLookup?()
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

actor DashboardStateScriptClient: AppleScriptClient {
    private let failingTrackIDs: Set<String>
    private let cancellingTrackIDs: Set<String>
    private let outcomeTrackIDs: Set<String>
    private let noChangeTrackIDs: Set<String>
    private let writeHold: LiveBatchHold?
    private var writes: [TrackPropertyUpdate] = []

    init(
        failingTrackIDs: Set<String> = [],
        cancellingTrackIDs: Set<String> = [],
        outcomeTrackIDs: Set<String> = [],
        noChangeTrackIDs: Set<String> = [],
        writeHold: LiveBatchHold? = nil
    ) {
        self.failingTrackIDs = failingTrackIDs
        self.cancellingTrackIDs = cancellingTrackIDs
        self.outcomeTrackIDs = outcomeTrackIDs
        self.noChangeTrackIDs = noChangeTrackIDs
        self.writeHold = writeHold
    }

    func initialize() async throws {
        // Test double has no external resources to initialize.
    }

    func runScript(
        name _: String,
        arguments _: [String],
        timeout _: Duration?
    ) async throws -> String? {
        nil
    }

    func fetchTracksByIDs(
        _ trackIDs: [String],
        batchSize _: Int,
        timeout _: Duration?
    ) async throws -> [Track] {
        trackIDs.map { Track(id: $0, name: "Track \($0)", artist: "Artist", album: "Album") }
    }

    func fetchAllTrackIDs(timeout _: Duration?) async throws -> [String] {
        []
    }

    func updateTrackProperty(trackID: String, property: String, value: String) async throws -> AppleScriptWriteResult {
        if let writeHold {
            await writeHold.holdOnce()
            try Task.checkCancellation()
        }
        if cancellingTrackIDs.contains(trackID) {
            throw CancellationError()
        }
        if outcomeTrackIDs.contains(trackID) {
            throw AppleScriptOutcomeError(scriptName: "update_property", duration: .seconds(3))
        }
        if failingTrackIDs.contains(trackID) {
            throw DashboardStateScriptWriteError(trackID: trackID)
        }
        writes.append(TrackPropertyUpdate(trackID: trackID, property: property, value: value))
        if noChangeTrackIDs.contains(trackID) {
            return .noChange
        }
        return .changed
    }

    func updateTrackProperty(
        trackID: String,
        property: String,
        value: String,
        onAttempt: @escaping WriteAttemptHook
    ) async throws -> AppleScriptWriteResult {
        let result: AppleScriptWriteResult
        do {
            result = try await updateTrackProperty(
                trackID: trackID,
                property: property,
                value: value
            )
        } catch let error as AppleScriptOutcomeError {
            try await onAttempt()
            throw error
        }
        try await onAttempt()
        return result
    }

    func batchUpdateTracks(_ updates: [TrackPropertyUpdate]) async throws {
        for update in updates {
            _ = try await updateTrackProperty(
                trackID: update.trackID,
                property: update.property,
                value: update.value
            )
        }
    }

    func batchUpdateTracks(
        _ updates: [TrackPropertyUpdate],
        onAttempt: @escaping WriteAttemptHook
    ) async throws {
        guard !updates.isEmpty else { return }
        var hasAttempted = false
        do {
            for update in updates {
                _ = try await updateTrackProperty(
                    trackID: update.trackID,
                    property: update.property,
                    value: update.value
                )
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

    func updatedProperties() -> [TrackPropertyUpdate] {
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

    func saveTracks(_: [Track]) async throws {
        // These tests do not assert persisted track state.
    }

    func deleteTrackIDs(_: [String]) async throws -> Int {
        0
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

    func setPersistent(key _: String, value _: some Codable & Sendable) async {
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
