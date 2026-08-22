// GeneralConfiguration.swift — shared application configuration sections.

import Foundation

// MARK: - Main Paths

public struct PathsConfig: Sendable, Codable {
    public static let defaultLogsBaseDirectory = "${APP_SUPPORT}/logs"
    public static let legacyTemporaryLogsBaseDirectory = "/tmp/mgu-logs" // NOSONAR - legacy migration sentinel.

    public var musicLibraryPath: String = "${HOME}/Music/Music/Music Library.musiclibrary"
    public var appleScriptsDirectory: String = "applescripts"
    public var logsBaseDirectory: String = Self.defaultLogsBaseDirectory
    public var apiCacheFile: String = "cache/cache.json"

    public var effectiveLogsBaseDirectory: String {
        logsBaseDirectory == Self.legacyTemporaryLogsBaseDirectory
            ? Self.defaultLogsBaseDirectory
            : logsBaseDirectory
    }

    private enum CodingKeys: String, CodingKey {
        case musicLibraryPath, appleScriptsDirectory, logsBaseDirectory, apiCacheFile
    }

    private enum DecodingKeys: String, CodingKey {
        case musicLibraryPath, appleScriptsDirectory, logsBaseDirectory, apiCacheFile
        case legacyMusicLibraryPath = "music_library_path"
        case legacyAppleScriptsDirectory = "apple_scripts_directory"
        case legacyLogsBaseDirectory = "logs_base_directory"
        case legacyApiCacheFile = "api_cache_file"
    }

    public init() {
        // Defaults are declared inline on each property.
    }

    public init(from decoder: any Decoder) throws {
        let defaults = Self()
        let container = try decoder.container(keyedBy: DecodingKeys.self)
        musicLibraryPath = try container.decodeIfPresent(String.self, forKey: .musicLibraryPath)
            ?? container.decodeIfPresent(String.self, forKey: .legacyMusicLibraryPath)
            ?? defaults.musicLibraryPath
        appleScriptsDirectory = try container.decodeIfPresent(String.self, forKey: .appleScriptsDirectory)
            ?? container.decodeIfPresent(String.self, forKey: .legacyAppleScriptsDirectory)
            ?? defaults.appleScriptsDirectory
        logsBaseDirectory = try container.decodeIfPresent(String.self, forKey: .logsBaseDirectory)
            ?? container.decodeIfPresent(String.self, forKey: .legacyLogsBaseDirectory)
            ?? defaults.logsBaseDirectory
        apiCacheFile = try container.decodeIfPresent(String.self, forKey: .apiCacheFile)
            ?? container.decodeIfPresent(String.self, forKey: .legacyApiCacheFile)
            ?? defaults.apiCacheFile
    }
}

public struct PythonSettingsConfig: Sendable, Codable {
    public var preventBytecode: Bool = true

    public init() {
        // Defaults are declared inline on each property.
    }
}

/// The automation strategy is a domain value, not a boolean (ADR 0003):
/// it decides trigger sources and cadence, never processing scope, mode,
/// or write authority. Relocated from Services (RunConfig captures it
/// per run) — the raw values are persisted in run records and must not
/// change.
public enum AutomationStrategy: String, Codable, CaseIterable, Equatable, Sendable, Identifiable {
    case manualOnly
    case libraryChange
    case scheduled
    case hybrid

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .manualOnly: "Manual only"
        case .libraryChange: "On library change"
        case .scheduled: "Scheduled"
        case .hybrid: "Hybrid"
        }
    }
}

public struct RuntimeConfig: Sendable, Codable {
    public var dryRun: Bool = false
    public var cacheTTLSeconds: Int = 1800
    public var incrementalIntervalMinutes: Int = 1
    public var automationStrategy: AutomationStrategy = .manualOnly
    public var maxRetries: Int = 3
    public var retryDelaySeconds: Double = 1
    public var maxGenericEntries: Int = 10000

    private enum CodingKeys: String, CodingKey {
        case dryRun, cacheTTLSeconds, incrementalIntervalMinutes, automationStrategy, maxRetries, retryDelaySeconds
        case maxGenericEntries
    }

    private enum DecodingKeys: String, CodingKey {
        case dryRun, cacheTTLSeconds, cacheTtlSeconds, incrementalIntervalMinutes, automationStrategy, maxRetries
        case retryDelaySeconds, maxGenericEntries
        case legacyCacheTTLSeconds = "cache_ttl_seconds"
    }

    public init() {
        // Defaults are declared inline on each property.
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DecodingKeys.self)
        dryRun = try container.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
        cacheTTLSeconds = try container.decodeIfPresent(Int.self, forKey: .cacheTTLSeconds)
            ?? container.decodeIfPresent(Int.self, forKey: .cacheTtlSeconds)
            ?? container.decodeIfPresent(Int.self, forKey: .legacyCacheTTLSeconds)
            ?? 1800
        incrementalIntervalMinutes = try container.decodeIfPresent(Int.self, forKey: .incrementalIntervalMinutes) ?? 1
        // An unknown raw value (a future strategy) must fall back, not
        // throw: a thrown keyNotFound-style failure silently resets the
        // user's whole configuration (see ReportingConfig precedent).
        automationStrategy = try container.decodeIfPresent(String.self, forKey: .automationStrategy)
            .flatMap(AutomationStrategy.init(rawValue:)) ?? .manualOnly
        maxRetries = try container.decodeIfPresent(Int.self, forKey: .maxRetries) ?? 3
        retryDelaySeconds = try container.decodeIfPresent(Double.self, forKey: .retryDelaySeconds) ?? 1
        maxGenericEntries = try container.decodeIfPresent(Int.self, forKey: .maxGenericEntries) ?? 10000
    }
}

// MARK: - Caching Configuration

public struct CachingConfig: Sendable, Codable {
    public var defaultTTLSeconds: Int = 900
    public var albumCacheSyncInterval: Int = 300
    public var cleanupErrorRetryDelay: Int = 60
    public var cleanupIntervalSeconds: Int = 300
    public var negativeResultTTL: Double = 3600
    public var librarySnapshot = LibrarySnapshotConfig()

    private enum CodingKeys: String, CodingKey {
        case defaultTTLSeconds, albumCacheSyncInterval, cleanupErrorRetryDelay, cleanupIntervalSeconds
        case negativeResultTTL, librarySnapshot
    }

    private enum DecodingKeys: String, CodingKey {
        case defaultTTLSeconds, albumCacheSyncInterval, cleanupErrorRetryDelay, cleanupIntervalSeconds
        case negativeResultTTL, librarySnapshot
        case defaultTtlSeconds, negativeResultTtl
        case legacyDefaultTTLSeconds = "default_ttl_seconds"
        case legacyAlbumCacheSyncInterval = "album_cache_sync_interval"
        case legacyCleanupErrorRetryDelay = "cleanup_error_retry_delay"
        case legacyCleanupIntervalSeconds = "cleanup_interval_seconds"
        case legacyNegativeResultTTL = "negative_result_ttl"
        case legacyLibrarySnapshot = "library_snapshot"
    }

    public init() {
        // Defaults are declared inline on each property.
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DecodingKeys.self)
        defaultTTLSeconds = try container.decodeIfPresent(Int.self, forKey: .defaultTTLSeconds)
            ?? container.decodeIfPresent(Int.self, forKey: .defaultTtlSeconds)
            ?? container.decodeIfPresent(Int.self, forKey: .legacyDefaultTTLSeconds)
            ?? 900
        albumCacheSyncInterval = try container.decodeIfPresent(Int.self, forKey: .albumCacheSyncInterval)
            ?? container.decodeIfPresent(Int.self, forKey: .legacyAlbumCacheSyncInterval) ?? 300
        cleanupErrorRetryDelay = try container.decodeIfPresent(Int.self, forKey: .cleanupErrorRetryDelay)
            ?? container.decodeIfPresent(Int.self, forKey: .legacyCleanupErrorRetryDelay) ?? 60
        cleanupIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .cleanupIntervalSeconds)
            ?? container.decodeIfPresent(Int.self, forKey: .legacyCleanupIntervalSeconds) ?? 300
        negativeResultTTL = try container.decodeIfPresent(Double.self, forKey: .negativeResultTTL)
            ?? container.decodeIfPresent(Double.self, forKey: .negativeResultTtl)
            ?? container.decodeIfPresent(Double.self, forKey: .legacyNegativeResultTTL)
            ?? 3600
        if let configuredSnapshot = try container
            .decodeIfPresent(LibrarySnapshotConfig.self, forKey: .librarySnapshot) {
            librarySnapshot = configuredSnapshot
        } else {
            librarySnapshot = try container.decodeIfPresent(LibrarySnapshotConfig.self, forKey: .legacyLibrarySnapshot)
                ?? LibrarySnapshotConfig()
        }
    }
}

public struct LibrarySnapshotConfig: Sendable, Codable {
    public var enabled: Bool = true
    public var cacheFile: String = "cache/library_snapshot.json"
    public var maxAgeHours: Int = 24
    public var compress: Bool = true
    public var compressLevel: Int = 6

    private enum CodingKeys: String, CodingKey {
        case enabled, cacheFile, maxAgeHours, compress, compressLevel
    }

    private enum DecodingKeys: String, CodingKey {
        case enabled, cacheFile, maxAgeHours, compress, compressLevel
        case legacyCacheFile = "cache_file"
        case legacyMaxAgeHours = "max_age_hours"
        case legacyCompressLevel = "compress_level"
    }

    public init() {
        // Defaults are declared inline on each property.
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DecodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        cacheFile = try container.decodeIfPresent(String.self, forKey: .cacheFile)
            ?? container.decodeIfPresent(String.self, forKey: .legacyCacheFile) ?? "cache/library_snapshot.json"
        maxAgeHours = try container.decodeIfPresent(Int.self, forKey: .maxAgeHours)
            ?? container.decodeIfPresent(Int.self, forKey: .legacyMaxAgeHours) ?? 24
        compress = try container.decodeIfPresent(Bool.self, forKey: .compress) ?? true
        compressLevel = try container.decodeIfPresent(Int.self, forKey: .compressLevel)
            ?? container.decodeIfPresent(Int.self, forKey: .legacyCompressLevel) ?? 6
    }
}

// MARK: - Analytics Configuration

public struct AnalyticsConfig: Sendable, Codable {
    public var enabled: Bool = false
    public var durationThresholds = DurationThresholdsConfig()
    public var maxEvents: Int = 10000
    public var recentEventLimit: Int = 100
    public var retentionDays: Int = 7

    private enum CodingKeys: String, CodingKey {
        case enabled, durationThresholds, maxEvents, recentEventLimit, retentionDays
    }

    private enum DecodingKeys: String, CodingKey {
        case enabled, durationThresholds, maxEvents, recentEventLimit, retentionDays
        case compactTime, timeFormat
    }

    public init() {
        // Defaults are declared inline on each property.
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DecodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        durationThresholds = try container.decodeIfPresent(
            DurationThresholdsConfig.self,
            forKey: .durationThresholds
        ) ?? DurationThresholdsConfig()
        maxEvents = try container.decodeIfPresent(Int.self, forKey: .maxEvents) ?? 10000
        recentEventLimit = try container.decodeIfPresent(Int.self, forKey: .recentEventLimit) ?? 100
        retentionDays = try container.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 7
    }
}

public struct DurationThresholdsConfig: Sendable, Codable {
    public var shortMax: Double = 5
    public var mediumMax: Double = 20
    public var longMax: Double = 50

    public init() {
        // Defaults are declared inline on each property.
    }
}

// MARK: - Reporting Configuration

public struct ReportingConfig: Sendable, Codable {
    public var minAttemptsForReport: Double = 3
    public var changeDisplayMode: ChangeDisplayMode = .compact
    /// Keeps the newest N prunable terminal run records. Open (interrupted)
    /// records, records with unresolved evidence, and continuation sources
    /// referenced by retained runs are kept on top and do not consume slots.
    public var runHistoryLimit: Int = 500

    public init() {
        // Defaults are declared inline on each property.
    }

    private enum CodingKeys: String, CodingKey {
        case minAttemptsForReport
        case changeDisplayMode
        case runHistoryLimit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        minAttemptsForReport = try container.decodeIfPresent(Double.self, forKey: .minAttemptsForReport) ?? 3
        changeDisplayMode = try container.decodeIfPresent(ChangeDisplayMode.self, forKey: .changeDisplayMode)
            ?? .compact
        runHistoryLimit = try container.decodeIfPresent(Int.self, forKey: .runHistoryLimit) ?? 500
    }
}

public enum ChangeDisplayMode: String, Sendable, Codable, CaseIterable {
    case compact
    case detailed
}

// MARK: - Logging Configuration

public struct LoggingConfig: Sendable, Codable {
    public var maxRuns: Int = 3
    public var mainLogFile: String = "main/main.log"
    public var analyticsLogFile: String = "analytics/analytics.log"
    public var lastIncrementalRunFile: String = "last_incremental_run.log"
    public var pendingVerificationFile: String = "csv/pending_year_verification.csv"
    public var lastDatabaseVerifyLog: String = "main/last_db_verify.log"
    public var levels = LogLevelsConfig()

    public init() {
        // Defaults are declared inline on each property.
    }
}

public struct LogLevelsConfig: Sendable, Codable {
    public var console: String = "INFO"
    public var mainFile: String = "DEBUG"
    public var analyticsFile: String = "INFO"

    public init() {
        // Defaults are declared inline on each property.
    }
}

// MARK: - Development Configuration

public struct DevelopmentConfig: Sendable, Codable {
    public var testArtists: [String] = []
    public var debugMode: Bool = false

    private enum CodingKeys: String, CodingKey {
        case testArtists, debugMode
    }

    public init() {
        // Defaults are declared inline on each property.
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        testArtists = try container.decodeIfPresent([String].self, forKey: .testArtists) ?? []
        debugMode = try container.decodeIfPresent(Bool.self, forKey: .debugMode) ?? false
    }
}
