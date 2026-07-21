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
    /// Pre-clamped score for debugging (can be negative).
    public let rawScore: Int
    public let yearScores: [Int: Int]

    public init(
        year: Int? = nil,
        isDefinitive: Bool = false,
        confidence: Int = 0,
        rawScore: Int? = nil,
        yearScores: [Int: Int] = [:]
    ) {
        self.year = year
        self.isDefinitive = isDefinitive
        self.confidence = confidence
        self.rawScore = rawScore ?? confidence
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
    public var lastForceScanDate: Date?

    public init(
        trackCount: Int,
        snapshotHash: String,
        timestamp: Date,
        libraryModificationDate: Date,
        lastForceScanDate: Date? = nil
    ) {
        self.trackCount = trackCount
        self.snapshotHash = snapshotHash
        self.timestamp = timestamp
        self.libraryModificationDate = libraryModificationDate
        self.lastForceScanDate = lastForceScanDate
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
    public struct RetryState: Sendable {
        public let attemptCount: Int
        public let lastAttempt: Date
        public let recheckInterval: TimeInterval

        public init(
            attemptCount: Int = 0,
            lastAttempt: Date = .now,
            recheckInterval: TimeInterval = 1_209_600
        ) {
            self.attemptCount = attemptCount
            self.lastAttempt = lastAttempt
            self.recheckInterval = recheckInterval
        }
    }

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
        retry: RetryState = RetryState(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.artist = artist
        self.album = album
        self.reason = reason
        self.attemptCount = retry.attemptCount
        self.lastAttempt = retry.lastAttempt
        self.recheckInterval = retry.recheckInterval
        self.metadata = metadata
    }
}

/// Typed row for albums that repeatedly failed pending verification.
public struct ProblematicPendingAlbum: Sendable, Codable, Identifiable {
    public let entry: PendingAlbumEntry
    public let totalAttempts: Int
    public let firstAttempt: Date
    public let lastAttempt: Date
    public let daysSinceFirstAttempt: Int
    public let status: String

    public var id: String {
        entry.id
    }

    public init(
        entry: PendingAlbumEntry,
        totalAttempts: Int,
        firstAttempt: Date,
        lastAttempt: Date,
        daysSinceFirstAttempt: Int,
        status: String = "Pending verification"
    ) {
        self.entry = entry
        self.totalAttempts = totalAttempts
        self.firstAttempt = firstAttempt
        self.lastAttempt = lastAttempt
        self.daysSinceFirstAttempt = daysSinceFirstAttempt
        self.status = status
    }
}

// MARK: - Cache Service

/// Protocol for cache operations (in-memory + persistent).
///
/// Implementors should be actors to guarantee thread-safe access.
/// Replaces CacheServiceProtocol from Python (220 LOC → ~40 LOC).
public protocol CacheService: Actor, Sendable {
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
    func invalidateAllAlbumYears() async

    // API result cache
    func getCachedAPIResult(artist: String, album: String, source: String) async -> CachedAPIResult?
    func setCachedAPIResult(_ result: CachedAPIResult) async
    func invalidateCachedAPIResults(artist: String, album: String) async

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

    /// Remove persisted tracks by their Music.app persistent IDs.
    @discardableResult
    func deleteTrackIDs(_ ids: [String]) async throws -> Int

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

    /// Return raw release candidates for album year scoring.
    ///
    /// Clients that cannot provide candidate lists may use the default empty
    /// implementation. Production API clients should override this so
    /// `YearDeterminator` can apply the same scoring pipeline used by Python.
    func getReleaseCandidates(
        artist: String,
        album: String,
        currentLibraryYear: Int?,
        earliestTrackAddedYear: Int?
    ) async throws -> [ReleaseCandidate]

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
}

// MARK: - AppleScript Client

/// Result of a single Music.app metadata write.
public enum AppleScriptWriteResult: Sendable, Equatable {
    case changed
    case noChange
}

/// Error thrown when a batch script may have run but its final metadata state cannot be verified.
public struct AppleScriptBatchVerificationError: Error, LocalizedError, Sendable, Equatable {
    public let updateCount: Int
    public let failedCount: Int?
    public let reason: String

    public init(updateCount: Int, failedCount: Int?, reason: String) {
        self.updateCount = updateCount
        self.failedCount = failedCount
        self.reason = reason
    }

    public var errorDescription: String? {
        if let failedCount {
            return "Batch verification failed for \(failedCount) of \(updateCount) updates: \(reason)"
        }
        return "Batch verification failed for \(updateCount) updates: \(reason)"
    }
}

/// Error thrown when an AppleScript read helper cannot map a non-empty record to a track.
public struct AppleScriptClientParseError: Error, LocalizedError, Sendable, Equatable {
    public let scriptName: String
    public let detail: String

    public var errorDescription: String? {
        "Failed to parse output from '\(scriptName)': \(detail)"
    }
}

/// Protocol for interacting with Music.app via AppleScript.
///
/// The actor requirement ensures serial access to AppleScript execution,
/// which avoids race conditions with Music.app.
public typealias WriteAttemptHook = @Sendable () async throws -> Void

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
    ///
    /// `batchSize` is clamped by the conformer to its supported range. `timeout`
    /// is the allowance for each batch; conformers must enforce one bounded
    /// deadline across the complete lookup, reject late final results, and ignore
    /// unresolved batches.
    func fetchTracksByIDs(
        _ trackIDs: [String],
        batchSize: Int,
        timeout: Duration?
    ) async throws -> [Track]

    /// Fetch all track IDs from the library (lightweight).
    func fetchAllTrackIDs(timeout: Duration?) async throws -> [String]

    /// Fetch editable tracks, optionally scoped to a single effective artist.
    func fetchTracks(artist: String?, timeout: Duration?) async throws -> [Track]

    /// Update a single property on a track in Music.app.йццйццц
    func updateTrackProperty(trackID: String, property: String, value: String) async throws -> AppleScriptWriteResult

    /// Update one property and report when Music.app has returned from the mutation attempt.
    func updateTrackProperty(
        trackID: String,
        property: String,
        value: String,
        onAttempt: @escaping WriteAttemptHook
    ) async throws -> AppleScriptWriteResult

    /// Update multiple track properties in one Music.app script call.
    ///
    /// A conformer must throw `AppleScriptBatchVerificationError` if the batch
    /// script may have reached Music.app but the resulting metadata cannot be
    /// verified. Callers use that error to avoid unsafe single-write fallback
    /// after a potentially mutating batch execution.
    func batchUpdateTracks(_ updates: [(trackID: String, property: String, value: String)]) async throws

    /// Update multiple properties and report after dispatch but before verification.
    func batchUpdateTracks(
        _ updates: [(trackID: String, property: String, value: String)],
        onAttempt: @escaping WriteAttemptHook
    ) async throws
}

extension AppleScriptClient {
    public func updateTrackProperty(
        trackID: String,
        property: String,
        value: String,
        onAttempt: @escaping WriteAttemptHook
    ) async throws -> AppleScriptWriteResult {
        let result: AppleScriptWriteResult
        do {
            result = try await updateTrackProperty(trackID: trackID, property: property, value: value)
        } catch {
            try await onAttempt()
            throw error
        }
        try await onAttempt()
        return result
    }

    public func batchUpdateTracks(
        _ updates: [(trackID: String, property: String, value: String)],
        onAttempt: @escaping WriteAttemptHook
    ) async throws {
        do {
            try await batchUpdateTracks(updates)
        } catch {
            try await onAttempt()
            throw error
        }
        try await onAttempt()
    }

    public func runScript(name: String, arguments: [String] = [], timeout: Duration? = nil) async throws -> String? {
        try await runScript(name: name, arguments: arguments, timeout: timeout)
    }

    public func fetchTracks(artist: String? = nil, timeout: Duration? = nil) async throws -> [Track] {
        let arguments = artist.map { [$0] } ?? []
        let output = try await runScript(
            name: "fetch_tracks",
            arguments: arguments,
            timeout: timeout
        )
        guard let output, output != "NO_TRACKS_FOUND" else { return [] }
        return try Self.parseTrackRecords(output, scriptName: "fetch_tracks")
    }

    public static func parseTrackRecords(_ output: String, scriptName: String) throws -> [Track] {
        var tracks: [Track] = []
        for record in output.split(separator: Track.recordSeparator, omittingEmptySubsequences: false) {
            let rawRecord = String(record)
            guard !rawRecord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            guard let track = Track.fromAppleScriptOutput(rawRecord) else {
                let fieldCount = rawRecord.split(separator: Track.fieldSeparator, omittingEmptySubsequences: false)
                    .count
                throw AppleScriptClientParseError(
                    scriptName: scriptName,
                    detail: "Malformed track record: expected 12 fields, got \(fieldCount)"
                )
            }
            tracks.append(track)
        }
        return tracks
    }
}

// MARK: - Pending Verification Service

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

    if normalizedReason == "pre_release" {
        return "prerelease"
    }
    return normalizedReason
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
    func clearSnapshot() async
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

// MARK: - Change Log Store

/// Protocol for persisting undo/redo change log entries (SwiftData-backed).
///
/// Survives app restarts so users can undo changes from previous sessions.
public protocol ChangeLogStore: Actor {
    func saveEntry(_ entry: ChangeLogEntry) async throws
    func saveEntries(_ entries: [ChangeLogEntry]) async throws
    func loadAll() async throws -> [ChangeLogEntry]
    func delete(entryID: UUID) async throws
    func deleteAll() async throws
}

// MARK: - Track ID Mapping

/// Maps between MusicKit IDs and AppleScript persistent IDs.
///
/// MusicKit uses numeric `MusicItemID` strings while AppleScript uses
/// hex persistent IDs. This protocol bridges the two ID spaces by
/// matching tracks on (name, artist, album) tuples.
public protocol TrackIDMapping: Sendable {
    /// Get the AppleScript persistent ID for a MusicKit track.
    func appleScriptID(forMusicKitID musicKitID: String) async -> String?

    /// Return a MusicKit-ID-preserving track enriched with AppleScript metadata.
    func trackWithAppleScriptMetadata(for musicKitTrack: Track) async -> Track?

    /// Build/refresh the mapping table from both ID sources.
    func refreshMapping(
        musicKitTracks: [Track],
        appleScriptTracks: [Track]
    ) async

    /// Whether a mapping exists for the given MusicKit ID.
    func hasMappingFor(musicKitID: String) async -> Bool
}

// MARK: - Analytics

/// Protocol for performance tracking and analytics instrumentation.
public protocol AnalyticsService: Sendable {
    func trackEvent(_ eventType: String, duration: Duration, metadata: [String: String]) async
    func trackError(_ eventType: String, error: any Error) async
}
