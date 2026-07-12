// AppleScriptConfiguration.swift — Music.app scripting configuration.

import Foundation

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

    private enum CodingKeys: String, CodingKey {
        case concurrency, timeouts, rateLimit, retry, batchProcessing
    }

    public init() {}

    public init(from decoder: any Decoder) throws {
        let defaults = Self()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        concurrency = try container.decodeIfPresent(Int.self, forKey: .concurrency) ?? defaults.concurrency
        timeouts = try container.decodeIfPresent(AppleScriptTimeouts.self, forKey: .timeouts) ?? defaults.timeouts
        rateLimit = try container.decodeIfPresent(AppleScriptRateLimit.self, forKey: .rateLimit) ?? defaults.rateLimit
        retry = try container.decodeIfPresent(AppleScriptRetry.self, forKey: .retry) ?? defaults.retry
        batchProcessing = try container.decodeIfPresent(BatchProcessingConfig.self, forKey: .batchProcessing)
            ?? defaults.batchProcessing
    }
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
        case legacyDefault = "default"
        case legacyFullLibraryFetchName = "fullLibraryFetch"
        case legacyFullLibraryFetch = "full_library_fetch"
        case legacySingleArtistFetchName = "singleArtistFetch"
        case legacySingleArtistFetch = "single_artist_fetch"
        case legacyBatchUpdateName = "batchUpdate"
        case legacyBatchUpdate = "batch_update"
        case legacyIdsBatchFetchName = "idsBatchFetch"
        case legacyIdsBatchFetch = "ids_batch_fetch"
    }

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultTimeout = try .seconds(
            container.decodeIfPresent(Int.self, forKey: .defaultTimeoutSeconds)
                ?? container.decodeIfPresent(Int.self, forKey: .legacyDefault)
                ?? 3600
        )
        fullLibraryFetch = try .seconds(
            container.decodeIfPresent(Int.self, forKey: .fullLibraryFetchSeconds)
                ?? container.decodeIfPresent(Int.self, forKey: .legacyFullLibraryFetchName)
                ?? container.decodeIfPresent(Int.self, forKey: .legacyFullLibraryFetch)
                ?? 3600
        )
        singleArtistFetch = try .seconds(
            container.decodeIfPresent(Int.self, forKey: .singleArtistFetchSeconds)
                ?? container.decodeIfPresent(Int.self, forKey: .legacySingleArtistFetchName)
                ?? container.decodeIfPresent(Int.self, forKey: .legacySingleArtistFetch)
                ?? 600
        )
        batchUpdate = try .seconds(
            container.decodeIfPresent(Int.self, forKey: .batchUpdateSeconds)
                ?? container.decodeIfPresent(Int.self, forKey: .legacyBatchUpdateName)
                ?? container.decodeIfPresent(Int.self, forKey: .legacyBatchUpdate)
                ?? 1800
        )
        idsBatchFetch = try .seconds(
            container.decodeIfPresent(Int.self, forKey: .idsBatchFetchSeconds)
                ?? container.decodeIfPresent(Int.self, forKey: .legacyIdsBatchFetchName)
                ?? container.decodeIfPresent(Int.self, forKey: .legacyIdsBatchFetch)
                ?? 120
        )
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
    public var enabled: Bool = true
    public var requestsPerWindow: Int = 10
    public var windowSizeSeconds: Double = 1.0

    private enum CodingKeys: String, CodingKey {
        case enabled, requestsPerWindow, windowSizeSeconds
    }

    private enum DecodingKeys: String, CodingKey {
        case enabled, requestsPerWindow, windowSizeSeconds
        case legacyRequestsPerWindow = "requests_per_window"
        case legacyWindowSizeSeconds = "window_size_seconds"
    }

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DecodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        requestsPerWindow = try container.decodeIfPresent(Int.self, forKey: .requestsPerWindow)
            ?? container.decodeIfPresent(Int.self, forKey: .legacyRequestsPerWindow)
            ?? 10
        windowSizeSeconds = try container.decodeIfPresent(Double.self, forKey: .windowSizeSeconds)
            ?? container.decodeIfPresent(Double.self, forKey: .legacyWindowSizeSeconds)
            ?? 1.0
    }
}

public struct AppleScriptRetry: Sendable, Codable {
    public var maxRetries: Int = 3
    public var baseDelaySeconds: Double = 1.0
    public var maxDelaySeconds: Double = 10.0
    public var jitterRange: Double = 0.2
    public var operationTimeoutSeconds: Double = 60.0

    private enum CodingKeys: String, CodingKey {
        case maxRetries, baseDelaySeconds, maxDelaySeconds, jitterRange, operationTimeoutSeconds
    }

    private enum DecodingKeys: String, CodingKey {
        case maxRetries, baseDelaySeconds, maxDelaySeconds, jitterRange, operationTimeoutSeconds
        case legacyMaxRetries = "max_retries"
        case legacyBaseDelaySeconds = "base_delay_seconds"
        case legacyMaxDelaySeconds = "max_delay_seconds"
        case legacyJitterRange = "jitter_range"
        case legacyOperationTimeoutSeconds = "operation_timeout_seconds"
    }

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DecodingKeys.self)
        maxRetries = try container.decodeIfPresent(Int.self, forKey: .maxRetries)
            ?? container.decodeIfPresent(Int.self, forKey: .legacyMaxRetries)
            ?? 3
        baseDelaySeconds = try container.decodeIfPresent(Double.self, forKey: .baseDelaySeconds)
            ?? container.decodeIfPresent(Double.self, forKey: .legacyBaseDelaySeconds)
            ?? 1.0
        maxDelaySeconds = try container.decodeIfPresent(Double.self, forKey: .maxDelaySeconds)
            ?? container.decodeIfPresent(Double.self, forKey: .legacyMaxDelaySeconds)
            ?? 10.0
        jitterRange = try container.decodeIfPresent(Double.self, forKey: .jitterRange)
            ?? container.decodeIfPresent(Double.self, forKey: .legacyJitterRange)
            ?? 0.2
        operationTimeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .operationTimeoutSeconds)
            ?? container.decodeIfPresent(Double.self, forKey: .legacyOperationTimeoutSeconds)
            ?? 60.0
    }
}

public struct BatchProcessingConfig: Sendable, Codable {
    /// Supported ID lookup batch sizes, matching the Python processing boundary.
    public static let idsBatchRange = 1 ... 1000

    /// Clamps an ID lookup batch size to the supported processing boundary.
    public static func clampIDBatch(_ size: Int) -> Int {
        min(idsBatchRange.upperBound, max(idsBatchRange.lowerBound, size))
    }

    public var idsBatchSize: Int = 200
    public var batchSize: Int = 1000

    private enum CodingKeys: String, CodingKey {
        case idsBatchSize, batchSize
    }

    private enum DecodingKeys: String, CodingKey {
        case idsBatchSize, batchSize
        case legacyIdsBatchSize = "ids_batch_size"
        case legacyBatchSize = "batch_size"
    }

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DecodingKeys.self)
        idsBatchSize = try container.decodeIfPresent(Int.self, forKey: .idsBatchSize)
            ?? container.decodeIfPresent(Int.self, forKey: .legacyIdsBatchSize)
            ?? 200
        batchSize = try container.decodeIfPresent(Int.self, forKey: .batchSize)
            ?? container.decodeIfPresent(Int.self, forKey: .legacyBatchSize)
            ?? 1000
    }
}
