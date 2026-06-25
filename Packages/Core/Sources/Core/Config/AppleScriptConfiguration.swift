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
