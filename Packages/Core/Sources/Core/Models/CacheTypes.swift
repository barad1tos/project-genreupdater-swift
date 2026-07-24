import Foundation

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
