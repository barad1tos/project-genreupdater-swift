import Foundation

/// Protocol for cache operations (in-memory + persistent).
public protocol CacheService: Actor, Sendable {
    func initialize() async throws
    func get<T: Codable & Sendable>(key: String) async -> T?
    func set(key: String, value: some Codable & Sendable, ttl: TimeInterval?) async
    func invalidate(key: String) async
    func clear() async
    func getAlbumYear(artist: String, album: String) async -> AlbumCacheEntry?
    func storeAlbumYear(artist: String, album: String, year: Int, confidence: Int) async
    func invalidateAlbum(artist: String, album: String) async
    func invalidateAllAlbumYears() async
    func getCachedAPIResult(artist: String, album: String, source: String) async -> CachedAPIResult?
    func setCachedAPIResult(_ result: CachedAPIResult) async
    func invalidateCachedAPIResults(artist: String, album: String) async
    func syncToDisk() async throws
}

/// Cache capability for values that must not expire by time.
public protocol PersistentCacheService: CacheService {
    /// Stores a value without time-based expiry; it remains removable by `invalidate(key:)`, `clear()`, or capacity
    /// eviction.
    func setPersistent(key: String, value: some Codable & Sendable) async
}

public enum TrackStoreError: LocalizedError, Sendable {
    case missingTrack(id: String)

    public var errorDescription: String? {
        switch self {
        case let .missingTrack(id):
            "Track state store has no track with ID \(id)"
        }
    }
}

/// Protocol for persisting the track metadata mirror and processing state.
public protocol TrackStateStore: Actor {
    func initialize() async throws
    func loadAllTracks() async throws -> [Track]
    func saveTracks(_ tracks: [Track]) async throws
    @discardableResult
    func deleteTrackIDs(_ ids: [String]) async throws -> Int
    func getTrack(byID id: String) async throws -> Track?
    /// Atomically persists metadata and processing flags for a change whose
    /// track ID is the canonical library read ID, never an AppleScript ID.
    func persistAppliedChange(_ change: ChangeLogEntry) async throws
    func getUnprocessedTracks() async throws -> [Track]
    func trackCount() async throws -> Int
}

/// Protocol for external music metadata API clients.
public protocol ExternalAPIService: Sendable {
    func getAlbumYear(
        artist: String,
        album: String,
        currentLibraryYear: Int?,
        earliestTrackAddedYear: Int?
    ) async throws -> YearResult

    func getReleaseCandidates(
        artist: String,
        album: String,
        currentLibraryYear: Int?,
        earliestTrackAddedYear: Int?
    ) async throws -> [ReleaseCandidate]

    func getArtistActivityPeriod(normalizedArtist: String) async throws -> (start: Int?, end: Int?)
    func getArtistStartYear(normalizedArtist: String) async throws -> Int?
    /// The artist's region NAME for release-country scoring; nil when
    /// the lookup SUCCEEDED but found no region (cacheable miss). A
    /// transport/decoding failure THROWS so callers never confuse it
    /// with a confirmed absence. Only MusicBrainz answers.
    func getArtistRegion(artist: String) async throws -> String?
    func initialize(force: Bool) async throws
    func close() async
}

extension ExternalAPIService {
    public func getReleaseCandidates(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> [ReleaseCandidate] {
        []
    }

    public func initialize(force: Bool = false) async throws {
        try await initialize(force: force)
    }

    public func close() async {
        // Services without retained connections have nothing to release.
    }

    public func getArtistRegion(artist _: String) async throws -> String? {
        nil
    }
}

/// Protocol for managing albums that need manual year verification.
public protocol PendingVerificationService: Actor, Sendable {
    func initialize() async throws
    func markForVerification(
        artist: String,
        album: String,
        reason: String,
        metadata: [String: String]?,
        recheckDays: Int?
    ) async
    func removeFromPending(artist: String, album: String) async
    func getEntry(artist: String, album: String) async -> PendingAlbumEntry?
    func getAttemptCount(artist: String, album: String) async -> Int
    func isVerificationNeeded(artist: String, album: String) async -> Bool
    func getAllPendingAlbums() async -> [PendingAlbumEntry]
    func getPendingAlbums(reason: String) async -> [PendingAlbumEntry]
    func getDuePendingAlbums() async -> [PendingAlbumEntry]
    func getPendingVerificationSnapshot() async -> (all: [PendingAlbumEntry], due: [PendingAlbumEntry])
    func getProblematicPendingAlbums(minAttempts: Int) async -> [ProblematicPendingAlbum]
    func shouldAutoVerify() async -> Bool
    func updateVerificationTimestamp() async throws
}

extension PendingVerificationService {
    public func getDuePendingAlbums() async -> [PendingAlbumEntry] {
        let allEntries = await getAllPendingAlbums()
        return await duePendingAlbums(from: allEntries)
    }

    public func getPendingVerificationSnapshot() async -> (all: [PendingAlbumEntry], due: [PendingAlbumEntry]) {
        let allEntries = await getAllPendingAlbums()
        let dueEntries = await duePendingAlbums(from: allEntries)
        return (allEntries, dueEntries)
    }

    public func getPendingAlbums(reason: String) async -> [PendingAlbumEntry] {
        let normalizedReason = normalizedPendingVerificationReason(reason)
        return await getAllPendingAlbums().filter {
            normalizedPendingVerificationReason($0.reason) == normalizedReason
        }
    }

    public func getProblematicPendingAlbums(minAttempts _: Int) async -> [ProblematicPendingAlbum] {
        []
    }

    private func duePendingAlbums(from entries: [PendingAlbumEntry]) async -> [PendingAlbumEntry] {
        var dueEntries: [PendingAlbumEntry] = []
        for entry in entries {
            let isDue = await isVerificationNeeded(artist: entry.artist, album: entry.album)
            guard isDue else { continue }
            dueEntries.append(entry)
        }
        return dueEntries
    }
}

private func normalizedPendingVerificationReason(_ reason: String) -> String {
    let normalizedReason = reason
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "-", with: "_")
        .lowercased()
    return normalizedReason == "pre_release" ? "prerelease" : normalizedReason
}

/// Token-bucket rate limiter for API calls.
public protocol RateLimiter: Actor {
    func acquire() async -> Duration
    func release()
    func getStats() -> RateLimiterStats
}

public struct RateLimiterStats: Sendable {
    public let totalRequests: Int
    public let totalWaitTime: Duration
    public let currentTokens: Int

    public init(totalRequests: Int, totalWaitTime: Duration, currentTokens: Int) {
        self.totalRequests = totalRequests
        self.totalWaitTime = totalWaitTime
        self.currentTokens = currentTokens
    }
}

/// Protocol for library snapshot persistence.
public protocol LibrarySnapshotService: Actor {
    func loadSnapshot() async throws -> [Track]?
    func saveSnapshot(_ tracks: [Track]) async throws -> String
    /// Invalidates cached tracks while retaining all snapshot metadata, including the force-refresh schedule.
    func clearSnapshot() async
    func isSnapshotValid() async -> Bool
    func getSnapshotMetadata() async -> LibraryCacheMetadata?
    func updateSnapshotMetadata(_ metadata: LibraryCacheMetadata) async throws
    func getLibraryModificationDate() async throws -> Date
    var isEnabled: Bool { get }
}

/// Protocol for track processing operations.
public protocol TrackProcessor: Sendable {
    func updateArtist(
        track: Track,
        newArtistName: String,
        originalArtist: String?,
        updateAlbumArtist: Bool
    ) async throws -> Bool
}

extension TrackProcessor {
    public func updateArtist(
        track: Track,
        newArtistName: String,
        originalArtist: String? = nil,
        updateAlbumArtist: Bool = true
    ) async throws -> Bool {
        try await updateArtist(
            track: track,
            newArtistName: newArtistName,
            originalArtist: originalArtist,
            updateAlbumArtist: updateAlbumArtist
        )
    }
}

public protocol ChangeLogStore: Actor {
    func saveEntry(_ entry: ChangeLogEntry) async throws
    func saveEntries(_ entries: [ChangeLogEntry]) async throws
    func loadAll() async throws -> [ChangeLogEntry]
    /// Newest-first bounded read for display surfaces; `loadAll` stays
    /// the undo/audit path.
    func loadRecent(limit: Int) async throws -> [ChangeLogEntry]
    func delete(entryID: UUID) async throws
    func deleteAll() async throws
}

public protocol TrackIDMapping: Sendable {
    func appleScriptID(forMusicKitID musicKitID: String) async -> String?
    func trackWithAppleScriptMetadata(for musicKitTrack: Track) async -> Track?
    func refreshMapping(musicKitTracks: [Track], appleScriptTracks: [Track]) async
    func hasMappingFor(musicKitID: String) async -> Bool
}

public protocol AnalyticsService: Sendable {
    /// Records one privacy-safe operation result.
    func record(_ operation: AnalyticsOperation, duration: Duration, outcome: AnalyticsOutcome) async
}

extension AnalyticsService {
    /// Measures an async operation while preserving its value and error behavior.
    public func measure<Value: Sendable>(
        _ operation: AnalyticsOperation,
        isolation _: isolated (any Actor)? = #isolation,
        errorOutcome: @Sendable (any Error, Bool) -> AnalyticsOutcome = {
            AnalyticsOutcome(error: $0, isTaskCancelled: $1)
        },
        body: () async throws -> Value
    ) async rethrows -> Value {
        let clock = ContinuousClock()
        let start = clock.now

        do {
            let value = try await body()
            await record(operation, duration: start.duration(to: clock.now), outcome: .succeeded)
            return value
        } catch {
            await record(
                operation,
                duration: start.duration(to: clock.now),
                outcome: errorOutcome(error, Task.isCancelled)
            )
            throw error
        }
    }
}
