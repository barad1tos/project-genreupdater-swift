// AppConfiguration.swift — Application configuration model
// Ported from: src/core/core_config.py (325 LOC) + track_models.py config models (400 LOC)
//
// Key differences from Python:
// - Codable replaces Pydantic BaseModel (compiler-synthesized conformance)
// - @AppStorage used in Views for persisted preferences
// - Keychain for API keys (not config file)
// - No YAML parsing needed — config stored as JSON in app container
// - Environment variable resolution not needed (GUI app, not CLI)
// - Validation via Swift's type system + throwing init where needed

import Foundation

// MARK: - Main Configuration

/// Root configuration for Genre Updater.
///
/// In the macOS app, configuration is managed through:
/// - Settings UI → @AppStorage (user preferences)
/// - Keychain → API keys (secure storage)
/// - This struct → serialized as JSON in app container (detailed settings)
///
/// For users migrating from the Python CLI, `AppConfiguration.fromLegacyYAML()`
/// can import their existing config.yaml.
public struct AppConfiguration: Sendable, Codable {
    public var applescript = AppleScriptConfig()
    public var yearRetrieval = YearRetrievalConfig()
    public var genreUpdate = GenreUpdateConfig()
    public var caching = CachingConfig()
    public var processing = ProcessingConfig()
    public var analytics = AnalyticsConfig()
    public var cleaning = CleaningConfig()
    public var development = DevelopmentConfig()

    public init() {}

    /// Load configuration from the app's container.
    public static func load() throws -> Self {
        let url = configFileURL
        guard FileManager.default.fileExists(atPath: url.path()) else {
            return Self()
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Self.self, from: data)
    }

    /// Save configuration to the app's container.
    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: Self.configFileURL, options: .atomic)
    }

    /// Path to the JSON config file in the app's Application Support directory.
    public static var configFileURL: URL {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            preconditionFailure("Application Support directory unavailable")
        }
        let appDir = appSupport.appendingPathComponent("GenreUpdater", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("config.json")
    }
}

// MARK: - AppleScript Configuration

public struct AppleScriptConfig: Sendable, Codable {
    /// Maximum concurrent AppleScript operations (2-3 is safe; >5 causes race conditions).
    public var concurrency: Int = 2

    /// Timeout settings per operation type.
    public var timeouts = AppleScriptTimeouts()

    /// Rate limiting for AppleScript operations.
    public var rateLimit = AppleScriptRateLimit()

    /// Retry policy for transient failures.
    public var retry = AppleScriptRetry()

    /// Batch processing sizes.
    public var batchProcessing = BatchProcessingConfig()

    public init() {}
}

public struct AppleScriptTimeouts: Sendable, Codable {
    public var defaultTimeout: Duration = .seconds(3600)
    public var fullLibraryFetch: Duration = .seconds(3600)
    public var singleArtistFetch: Duration = .seconds(600)
    public var batchUpdate: Duration = .seconds(1800)
    public var idsBatchFetch: Duration = .seconds(120)

    private enum CodingKeys: String, CodingKey {
        case defaultTimeoutSeconds, fullLibraryFetchSeconds, singleArtistFetchSeconds
        case batchUpdateSeconds, idsBatchFetchSeconds
    }

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultTimeout = try .seconds(container.decodeIfPresent(Int.self, forKey: .defaultTimeoutSeconds) ?? 3600)
        fullLibraryFetch = try .seconds(container.decodeIfPresent(Int.self, forKey: .fullLibraryFetchSeconds) ?? 3600)
        singleArtistFetch = try .seconds(container.decodeIfPresent(Int.self, forKey: .singleArtistFetchSeconds) ?? 600)
        batchUpdate = try .seconds(container.decodeIfPresent(Int.self, forKey: .batchUpdateSeconds) ?? 1800)
        idsBatchFetch = try .seconds(container.decodeIfPresent(Int.self, forKey: .idsBatchFetchSeconds) ?? 120)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Int(defaultTimeout.timeInterval), forKey: .defaultTimeoutSeconds)
        try container.encode(Int(fullLibraryFetch.timeInterval), forKey: .fullLibraryFetchSeconds)
        try container.encode(Int(singleArtistFetch.timeInterval), forKey: .singleArtistFetchSeconds)
        try container.encode(Int(batchUpdate.timeInterval), forKey: .batchUpdateSeconds)
        try container.encode(Int(idsBatchFetch.timeInterval), forKey: .idsBatchFetchSeconds)
    }
}

public struct AppleScriptRateLimit: Sendable, Codable {
    public var enabled: Bool = false
    public var requestsPerWindow: Int = 10
    public var windowSizeSeconds: Double = 1.0

    public init() {}
}

public struct AppleScriptRetry: Sendable, Codable {
    public var maxRetries: Int = 3
    public var baseDelaySeconds: Double = 1.0
    public var maxDelaySeconds: Double = 10.0
    public var jitterRange: Double = 0.2
    public var operationTimeoutSeconds: Double = 60.0

    public init() {}
}

public struct BatchProcessingConfig: Sendable, Codable {
    public var idsBatchSize: Int = 200
    public var batchSize: Int = 1000

    public init() {}
}

// MARK: - Year Retrieval Configuration

public struct YearRetrievalConfig: Sendable, Codable {
    public var enabled: Bool = true
    public var preferredAPI: PreferredAPI = .musicbrainz

    public var rateLimits = APIRateLimits()
    public var logic = YearLogicConfig()
    public var scoring = ScoringConfig()
    public var fallback = FallbackConfig()

    /// API priority per script type (e.g., "latin" → prefer musicbrainz).
    public var scriptAPIPriorities: [String: ScriptAPIPriority] = [:]

    public init() {}
}

public enum PreferredAPI: String, Sendable, Codable, CaseIterable {
    case musicbrainz
    case discogs
    case itunes
}

public struct APIRateLimits: Sendable, Codable {
    public var discogsRequestsPerMinute: Int = 25
    public var musicbrainzRequestsPerSecond: Double = 1.0
    public var concurrentAPICalls: Int = 3

    public init() {}
}

public struct YearLogicConfig: Sendable, Codable {
    public var minValidYear: Int = 1900
    public var absurdYearThreshold: Int = 1970
    public var suspicionThresholdYears: Int = 10
    public var definitiveScoreThreshold: Int = 80
    public var definitiveScoreDiff: Int = 20
    public var minConfidenceForNewYear: Double = 30
    public var preferredCountries: [String] = ["US", "GB", "DE", "JP"]
    public var majorMarketCodes: [String] = ["US", "GB", "DE", "JP", "AU", "CA", "FR"]
    public var dominantYearMinConfidence: Double = 0.8

    public init() {}
}

public struct ScoringConfig: Sendable, Codable {
    /// Base
    public var baseScore: Int = 50

    // Artist matching
    public var artistExactMatchBonus: Int = 30
    public var artistSubstringPenalty: Int = -20
    public var artistCrossScriptPenalty: Int = -10
    public var artistMismatchPenalty: Int = -60

    // Album matching
    public var albumExactMatchBonus: Int = 25
    public var perfectMatchBonus: Int = 40
    public var albumVariationBonus: Int = 15
    public var albumSubstringPenalty: Int = -15
    public var albumUnrelatedPenalty: Int = -50

    /// Soundtrack: intentionally high to offset expected artist mismatch
    /// on soundtracks (various artists vs. original performer).
    public var soundtrackCompensationBonus: Int = 75

    // Release characteristics
    public var mbReleaseGroupMatchBonus: Int = 20
    public var typeAlbumBonus: Int = 10
    public var typeEPSinglePenalty: Int = -5
    public var typeCompilationLivePenalty: Int = -15
    public var statusOfficialBonus: Int = 10
    public var statusBootlegPenalty: Int = -30
    public var statusPromoPenalty: Int = -10
    public var reissuePenalty: Int = -20

    // Year difference
    public var yearDiffPenaltyScale: Int = -5
    public var yearDiffMaxPenalty: Int = -50

    // Artist activity period
    public var yearBeforeStartPenalty: Int = -30
    public var yearAfterEndPenalty: Int = -15
    public var yearNearStartBonus: Int = 10

    // Country/region
    public var countryArtistMatchBonus: Int = 5
    public var countryMajorMarketBonus: Int = 3

    // Source reliability
    public var sourceMBBonus: Int = 10
    public var sourceDiscogsBonus: Int = 5
    public var sourceITunesBonus: Int = 0

    // Year penalties
    public var futureYearPenalty: Int = -10
    public var currentYearPenalty: Int = 0

    public init() {}
}

public struct FallbackConfig: Sendable, Codable {
    public var enabled: Bool = true
    public var yearDifferenceThreshold: Int = 5
    public var trustAPIScoreThreshold: Double = 70
    public var maxVerificationAttempts: Int = 3

    public init() {}
}

public struct ScriptAPIPriority: Sendable, Codable {
    public var primary: [String]
    public var fallback: [String] = []

    public init(primary: [String], fallback: [String] = []) {
        self.primary = primary
        self.fallback = fallback
    }
}

// MARK: - Genre Update Configuration

public struct GenreUpdateConfig: Sendable, Codable {
    public var batchSize: Int = 50
    public var concurrentLimit: Int = 5
    public var overrideExisting: Bool = false

    public init() {}
}

// MARK: - Caching Configuration

public struct CachingConfig: Sendable, Codable {
    public var defaultTTLSeconds: Int = 900
    public var albumCacheSyncInterval: Int = 300
    public var cleanupIntervalSeconds: Int = 300
    public var negativeResultTTL: Double = 2_592_000 // 30 days
    public var librarySnapshot = LibrarySnapshotConfig()

    public init() {}
}

public struct LibrarySnapshotConfig: Sendable, Codable {
    public var enabled: Bool = true
    public var deltaEnabled: Bool = true
    public var maxAgeHours: Int = 24

    public init() {}
}

// MARK: - Processing Configuration

public struct ProcessingConfig: Sendable, Codable {
    public var batchSize: Int = 50
    public var delayBetweenBatches: Double = 0.5
    public var adaptiveDelay: Bool = true
    public var cacheTTLDays: Int = 30
    public var pendingVerificationIntervalDays: Int = 14
    public var skipPrerelease: Bool = true
    public var futureYearThreshold: Int = 1
    public var prereleaseRecheckDays: Int = 30
    public var incrementalIntervalMinutes: Int = 15
    public var minConfidenceToCache: Int = 50
    public var suspiciousAlbumMinLen: Int = 3
    public var suspiciousManyYears: Int = 3

    public init() {}
}

// MARK: - Analytics Configuration

public struct AnalyticsConfig: Sendable, Codable {
    public var enabled: Bool = true
    public var maxEvents: Int = 10000

    public init() {}
}

// MARK: - Cleaning Configuration

public struct CleaningConfig: Sendable, Codable {
    // swiftlint:disable:next inclusive_language
    public var remasterKeywords: [String] = [
        "remaster", "remastered", "deluxe", "expanded", "anniversary",
        "special edition", "bonus track",
    ]
    public var albumSuffixesToRemove: [String] = [
        " (Remastered)", " (Deluxe)", " (Deluxe Edition)",
        " (Expanded Edition)", " (Special Edition)",
    ]
    public var trackCleaningExceptions: [TrackCleaningException] = []

    public init() {}
}

public struct TrackCleaningException: Sendable, Codable {
    public let artist: String
    public let album: String

    public init(artist: String, album: String) {
        self.artist = artist
        self.album = album
    }
}

// MARK: - Development Configuration

public struct DevelopmentConfig: Sendable, Codable {
    public var testArtists: [String] = []
    public var debugMode: Bool = false

    public init() {}
}
