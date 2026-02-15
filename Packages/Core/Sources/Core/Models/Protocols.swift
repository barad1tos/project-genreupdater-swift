// Protocols.swift — Service protocol definitions
// Ported from: src/core/models/protocols.py (773 LOC → ~280 LOC)
//
// Swift protocols are more concise than Python's structural typing:
// - No @runtime_checkable needed (nominal typing)
// - No overloads (generics + optionals handle dispatch)
// - Associated types replace Python TypeVar
// - actor protocol replaces manual thread-safety

import Foundation

// MARK: - Year Result Types

/// Result of a year determination from an API source.
public struct YearResult: Sendable, Codable, Equatable {
    public let year: Int?
    public let isDefinitive: Bool
    public let confidence: Int
    public let yearScores: [Int: Int]

    public init(year: Int? = nil, isDefinitive: Bool = false, confidence: Int = 0, yearScores: [Int: Int] = [:]) {
        self.year = year
        self.isDefinitive = isDefinitive
        self.confidence = confidence
        self.yearScores = yearScores
    }
}

/// Cached result from an external API query.
public struct CachedAPIResult: Sendable, Codable, Equatable {
    public let artist: String
    public let album: String
    public let year: Int?
    public let source: String
    public let timestamp: Date
    public let ttl: TimeInterval?
    public let metadata: [String: String]

    public var isExpired: Bool {
        guard let ttl else { return false }
        return Date.now > timestamp.addingTimeInterval(ttl)
    }

    public init(
        artist: String,
        album: String,
        year: Int?,
        source: String,
        timestamp: Date,
        ttl: TimeInterval?,
        metadata: [String: String] = [:]
    ) {
        self.artist = artist
        self.album = album
        self.year = year
        self.source = source
        self.timestamp = timestamp
        self.ttl = ttl
        self.metadata = metadata
    }
}

/// Entry for an album's cached year data.
public struct AlbumCacheEntry: Sendable, Codable, Equatable {
    public let artist: String
    public let album: String
    public let year: Int?
    public let confidence: Int
    public let timestamp: Date

    public init(artist: String, album: String, year: Int?, confidence: Int, timestamp: Date) {
        self.artist = artist
        self.album = album
        self.year = year
        self.confidence = confidence
        self.timestamp = timestamp
    }
}

/// Metadata about the library snapshot.
public struct LibraryCacheMetadata: Sendable, Codable {
    public var trackCount: Int
    public var snapshotHash: String
    public var timestamp: Date
    public var libraryModificationDate: Date

    public init(trackCount: Int, snapshotHash: String, timestamp: Date, libraryModificationDate: Date) {
        self.trackCount = trackCount
        self.snapshotHash = snapshotHash
        self.timestamp = timestamp
        self.libraryModificationDate = libraryModificationDate
    }
}

/// Delta cache tracking changes between snapshots.
public struct LibraryDeltaCache: Sendable, Codable {
    public var addedIDs: Set<String>
    public var removedIDs: Set<String>
    public var modifiedIDs: Set<String>
    public var timestamp: Date

    public init(addedIDs: Set<String>, removedIDs: Set<String>, modifiedIDs: Set<String>, timestamp: Date) {
        self.addedIDs = addedIDs
        self.removedIDs = removedIDs
        self.modifiedIDs = modifiedIDs
        self.timestamp = timestamp
    }
}

/// Entry for an album pending manual verification.
public struct PendingAlbumEntry: Sendable, Codable, Identifiable {
    public let id: String
    public let artist: String
    public let album: String
    public let reason: String
    public var attemptCount: Int
    public var lastAttempt: Date
    public var recheckInterval: TimeInterval
    public var metadata: [String: String]

    public init(
        id: String,
        artist: String,
        album: String,
        reason: String,
        attemptCount: Int = 0,
        lastAttempt: Date = .now,
        recheckInterval: TimeInterval = 1_209_600,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.artist = artist
        self.album = album
        self.reason = reason
        self.attemptCount = attemptCount
        self.lastAttempt = lastAttempt
        self.recheckInterval = recheckInterval
        self.metadata = metadata
    }
}

// MARK: - Cache Service

/// Protocol for cache operations (in-memory + persistent).
///
/// Implementors should be actors to guarantee thread-safe access.
/// Replaces CacheServiceProtocol from Python (220 LOC → ~40 LOC).
public protocol CacheService: Actor {
    func initialize() async throws

    // Generic key-value cache
    func get<T: Codable & Sendable>(key: String) async -> T?
    func set(key: String, value: some Codable & Sendable, ttl: TimeInterval?) async
    func invalidate(key: String) async
    func clear() async

    // Album year cache
    func getAlbumYear(artist: String, album: String) async -> AlbumCacheEntry?
    func storeAlbumYear(artist: String, album: String, year: Int, confidence: Int) async
    func invalidateAlbum(artist: String, album: String) async

    // API result cache
    func getCachedAPIResult(artist: String, album: String, source: String) async -> CachedAPIResult?
    func setCachedAPIResult(_ result: CachedAPIResult) async

    /// Persistence
    func syncToDisk() async throws
}

// MARK: - Track State Store

/// Protocol for persisting track processing state (SwiftData-backed).
///
/// Replaces Python's in-memory track dictionary with a persistent store
/// that survives app restarts and supports 30K+ track libraries.
public protocol TrackStateStore: Actor {
    /// Set up the persistent store (create schema, run migrations).
    func initialize() async throws

    /// Load all persisted tracks.
    func loadAllTracks() async throws -> [Track]

    /// Persist a batch of tracks (insert or update).
    func saveTracks(_ tracks: [Track]) async throws

    /// Retrieve a single track by its Music.app persistent ID.
    func getTrack(byID id: String) async throws -> Track?

    /// Update processing state flags for a track.
    func updateTrackProcessingState(
        id: String,
        genreUpdated: Bool?,
        yearUpdated: Bool?
    ) async throws

    /// Retrieve tracks that haven't been fully processed yet.
    func getUnprocessedTracks() async throws -> [Track]

    /// Total number of persisted tracks.
    func trackCount() async throws -> Int
}

// MARK: - External API Service

/// Protocol for external music metadata API clients (MusicBrainz, Discogs, Last.fm).
public protocol ExternalAPIService: Sendable {
    /// Determine the original release year for an album.
    func getAlbumYear(
        artist: String,
        album: String,
        currentLibraryYear: Int?,
        earliestTrackAddedYear: Int?
    ) async throws -> YearResult

    /// Retrieve the period of activity for an artist.
    func getArtistActivityPeriod(normalizedArtist: String) async throws -> (start: Int?, end: Int?)

    /// Get artist's career start year.
    func getArtistStartYear(normalizedArtist: String) async throws -> Int?

    /// Initialize the service (e.g., load auth tokens).
    func initialize(force: Bool) async throws

    /// Clean up connections.
    func close() async
}

extension ExternalAPIService {
    public func initialize(force: Bool = false) async throws {
        try await initialize(force: force)
    }

    public func close() async {}
}

// MARK: - AppleScript Client

/// Protocol for interacting with Music.app via AppleScript.
///
/// The actor requirement ensures serial access to AppleScript execution,
/// which avoids race conditions with Music.app.
public protocol AppleScriptClient: Actor {
    /// Initialize the client (validate scripts exist, etc.).
    func initialize() async throws

    /// Run an AppleScript file and return its output.
    func runScript(
        name: String,
        arguments: [String],
        timeout: Duration?
    ) async throws -> String?

    /// Fetch tracks by their persistent IDs.
    func fetchTracksByIDs(
        _ trackIDs: [String],
        batchSize: Int,
        timeout: Duration?
    ) async throws -> [Track]

    /// Fetch all track IDs from the library (lightweight).
    func fetchAllTrackIDs(timeout: Duration?) async throws -> [String]
}

extension AppleScriptClient {
    public func runScript(name: String, arguments: [String] = [], timeout: Duration? = nil) async throws -> String? {
        try await runScript(name: name, arguments: arguments, timeout: timeout)
    }

    public func fetchTracksByIDs(
        _ trackIDs: [String],
        batchSize: Int = 1000,
        timeout: Duration? = nil
    ) async throws -> [Track] {
        try await fetchTracksByIDs(trackIDs, batchSize: batchSize, timeout: timeout)
    }

    public func fetchAllTrackIDs(timeout: Duration? = nil) async throws -> [String] {
        try await fetchAllTrackIDs(timeout: timeout)
    }
}

// MARK: - Pending Verification Service

/// Protocol for managing albums that need manual year verification.
public protocol PendingVerificationService: Actor {
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
    func shouldAutoVerify() async -> Bool
    func updateVerificationTimestamp() async throws
}

// MARK: - Rate Limiter

/// Token-bucket rate limiter for API calls.
public protocol RateLimiter: Actor {
    /// Acquire permission to make a request. Returns wait time.
    func acquire() async -> Duration

    /// Release a request slot (for error cleanup).
    func release()

    /// Current statistics.
    func getStats() -> RateLimiterStats
}

/// Statistics from a rate limiter instance.
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

// MARK: - Library Snapshot Service

/// Protocol for library snapshot persistence and delta tracking.
public protocol LibrarySnapshotService: Actor {
    func loadSnapshot() async throws -> [Track]?
    func saveSnapshot(_ tracks: [Track]) async throws -> String
    func isSnapshotValid() async -> Bool
    func getSnapshotMetadata() async -> LibraryCacheMetadata?
    func updateSnapshotMetadata(_ metadata: LibraryCacheMetadata) async throws
    func loadDelta() async -> LibraryDeltaCache?
    func saveDelta(_ delta: LibraryDeltaCache) async throws
    func getLibraryModificationDate() async throws -> Date
    var isEnabled: Bool { get }
    var isDeltaEnabled: Bool { get }
}

// MARK: - Track Processor

/// Protocol for track processing operations (used by ArtistRenamer, etc.).
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

// MARK: - Analytics

/// Protocol for performance tracking and analytics instrumentation.
public protocol AnalyticsService: Sendable {
    func trackEvent(_ eventType: String, duration: Duration, metadata: [String: String]) async
    func trackError(_ eventType: String, error: any Error) async
}
