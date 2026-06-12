// GeneralConfiguration.swift — shared application configuration sections.

import Foundation

// MARK: - Main Paths

public struct PathsConfig: Sendable, Codable {
    public var musicLibraryPath: String = "${HOME}/Music/Music/Music Library.musiclibrary"
    public var appleScriptsDirectory: String = "applescripts"
    public var logsBaseDirectory: String = "/tmp/mgu-logs"
    public var apiCacheFile: String = "cache/cache.json"
    public var albumYearsCacheFile: String = "cache/album_years.csv"

    public init() {}
}

public struct PythonSettingsConfig: Sendable, Codable {
    public var preventBytecode: Bool = true

    public init() {}
}

public struct RuntimeConfig: Sendable, Codable {
    public var dryRun: Bool = false
    public var cacheTTLSeconds: Int = 1800
    public var incrementalIntervalMinutes: Int = 1
    public var maxRetries: Int = 3
    public var retryDelaySeconds: Double = 1
    public var maxGenericEntries: Int = 10000

    public init() {}
}

// MARK: - Caching Configuration

public struct CachingConfig: Sendable, Codable {
    public var defaultTTLSeconds: Int = 900
    public var albumCacheSyncInterval: Int = 300
    public var cleanupErrorRetryDelay: Int = 60
    public var cleanupIntervalSeconds: Int = 300
    public var negativeResultTTL: Double = 2_592_000
    public var librarySnapshot = LibrarySnapshotConfig()

    private enum CodingKeys: String, CodingKey {
        case defaultTTLSeconds, albumCacheSyncInterval, cleanupErrorRetryDelay, cleanupIntervalSeconds
        case negativeResultTTL, librarySnapshot
    }

    private enum DecodingKeys: String, CodingKey {
        case defaultTTLSeconds, albumCacheSyncInterval, cleanupErrorRetryDelay, cleanupIntervalSeconds
        case negativeResultTTL, librarySnapshot
        case legacyDefaultTTLSeconds = "default_ttl_seconds"
        case legacyAlbumCacheSyncInterval = "album_cache_sync_interval"
        case legacyCleanupErrorRetryDelay = "cleanup_error_retry_delay"
        case legacyCleanupIntervalSeconds = "cleanup_interval_seconds"
        case legacyNegativeResultTTL = "negative_result_ttl"
        case legacyLibrarySnapshot = "library_snapshot"
    }

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DecodingKeys.self)
        defaultTTLSeconds = try container.decodeIfPresent(Int.self, forKey: .defaultTTLSeconds)
            ?? container.decodeIfPresent(Int.self, forKey: .legacyDefaultTTLSeconds) ?? 900
        albumCacheSyncInterval = try container.decodeIfPresent(Int.self, forKey: .albumCacheSyncInterval)
            ?? container.decodeIfPresent(Int.self, forKey: .legacyAlbumCacheSyncInterval) ?? 300
        cleanupErrorRetryDelay = try container.decodeIfPresent(Int.self, forKey: .cleanupErrorRetryDelay)
            ?? container.decodeIfPresent(Int.self, forKey: .legacyCleanupErrorRetryDelay) ?? 60
        cleanupIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .cleanupIntervalSeconds)
            ?? container.decodeIfPresent(Int.self, forKey: .legacyCleanupIntervalSeconds) ?? 300
        negativeResultTTL = try container.decodeIfPresent(Double.self, forKey: .negativeResultTTL)
            ?? container.decodeIfPresent(Double.self, forKey: .legacyNegativeResultTTL) ?? 2_592_000
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
    public var deltaEnabled: Bool = true
    public var cacheFile: String = "cache/library_snapshot.json"
    public var maxAgeHours: Int = 24
    public var compress: Bool = true
    public var compressLevel: Int = 6

    private enum CodingKeys: String, CodingKey {
        case enabled, deltaEnabled, cacheFile, maxAgeHours, compress, compressLevel
    }

    private enum DecodingKeys: String, CodingKey {
        case enabled, deltaEnabled, cacheFile, maxAgeHours, compress, compressLevel
        case legacyDeltaEnabled = "delta_enabled"
        case legacyCacheFile = "cache_file"
        case legacyMaxAgeHours = "max_age_hours"
        case legacyCompressLevel = "compress_level"
    }

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DecodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        deltaEnabled = try container.decodeIfPresent(Bool.self, forKey: .deltaEnabled)
            ?? container.decodeIfPresent(Bool.self, forKey: .legacyDeltaEnabled) ?? true
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
    public var compactTime: Bool = true
    public var timeFormat: String = "%Y-%m-%d %H:%M:%S"
    public var enableGarbageCollection: Bool = true

    private enum CodingKeys: String, CodingKey {
        case enabled, durationThresholds, maxEvents, compactTime, timeFormat, enableGarbageCollection
    }

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        durationThresholds = try container.decodeIfPresent(
            DurationThresholdsConfig.self,
            forKey: .durationThresholds
        ) ?? DurationThresholdsConfig()
        maxEvents = try container.decodeIfPresent(Int.self, forKey: .maxEvents) ?? 10000
        compactTime = try container.decodeIfPresent(Bool.self, forKey: .compactTime) ?? true
        timeFormat = try container.decodeIfPresent(String.self, forKey: .timeFormat) ?? "%Y-%m-%d %H:%M:%S"
        enableGarbageCollection = try container.decodeIfPresent(Bool.self, forKey: .enableGarbageCollection) ?? true
    }
}

public struct DurationThresholdsConfig: Sendable, Codable {
    public var shortMax: Double = 5
    public var mediumMax: Double = 20
    public var longMax: Double = 50

    public init() {}
}

// MARK: - Reporting Configuration

public struct ReportingConfig: Sendable, Codable {
    public var problematicAlbumsPath: String = "reports/albums_without_year.csv"
    public var minAttemptsForReport: Double = 3
    public var changeDisplayMode: ChangeDisplayMode = .compact

    public init() {}
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
    public var csvOutputFile: String = "csv/track_list.csv"
    public var changesReportFile: String = "csv/changes_report.csv"
    public var dryRunReportFile: String = "reports/dry_run_report.html"
    public var lastIncrementalRunFile: String = "last_incremental_run.log"
    public var pendingVerificationFile: String = "csv/pending_year_verification.csv"
    public var lastDatabaseVerifyLog: String = "main/last_db_verify.log"
    public var levels = LogLevelsConfig()

    public init() {}
}

public struct LogLevelsConfig: Sendable, Codable {
    public var console: String = "INFO"
    public var mainFile: String = "DEBUG"
    public var analyticsFile: String = "INFO"

    public init() {}
}

// MARK: - Development Configuration

public struct DevelopmentConfig: Sendable, Codable {
    public var testArtists: [String] = []
    public var debugMode: Bool = false

    public init() {}
}
