// WorkflowConfiguration.swift — metadata, verification, and workflow configuration.

import Foundation

// MARK: - Genre Update Configuration

public struct GenreUpdateConfig: Sendable, Codable {
    public var batchSize: Int = 50
    public var concurrentLimit: Int = 5
    public var overrideExisting: Bool = false

    public init() {}
}

// MARK: - Processing Configuration

public struct ProcessingConfig: Sendable, Codable {
    public var batchSize: Int = 25
    public var delayBetweenBatches: Double = 20
    public var adaptiveDelay: Bool = true
    public var cacheTTLDays: Int = 36500
    public var pendingVerificationIntervalDays: Int = 30
    public var skipPrerelease: Bool = true
    public var futureYearThreshold: Int = 1
    public var prereleaseRecheckDays: Int = 30
    public var prereleaseHandling: PrereleaseHandling = .processEditable
    public var releaseYearRestoreThreshold: Int = 5
    public var incrementalIntervalMinutes: Int = 1
    public var minConfidenceToCache: Int = 50
    public var suspiciousAlbumMinLen: Int = 3
    public var suspiciousManyYears: Int = 3

    private enum CodingKeys: String, CodingKey {
        case batchSize, delayBetweenBatches, adaptiveDelay, cacheTTLDays, pendingVerificationIntervalDays
        case skipPrerelease, futureYearThreshold, prereleaseRecheckDays, prereleaseHandling
        case releaseYearRestoreThreshold, incrementalIntervalMinutes, minConfidenceToCache, suspiciousAlbumMinLen
        case suspiciousManyYears
    }

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        batchSize = try container.decodeIfPresent(Int.self, forKey: .batchSize) ?? 25
        delayBetweenBatches = try container.decodeIfPresent(Double.self, forKey: .delayBetweenBatches) ?? 20
        adaptiveDelay = try container.decodeIfPresent(Bool.self, forKey: .adaptiveDelay) ?? true
        cacheTTLDays = try container.decodeIfPresent(Int.self, forKey: .cacheTTLDays) ?? 36500
        pendingVerificationIntervalDays = try container.decodeIfPresent(
            Int.self,
            forKey: .pendingVerificationIntervalDays
        ) ?? 30
        skipPrerelease = try container.decodeIfPresent(Bool.self, forKey: .skipPrerelease) ?? true
        futureYearThreshold = try container.decodeIfPresent(Int.self, forKey: .futureYearThreshold) ?? 1
        prereleaseRecheckDays = try container.decodeIfPresent(Int.self, forKey: .prereleaseRecheckDays) ?? 30
        prereleaseHandling = try container
            .decodeIfPresent(PrereleaseHandling.self, forKey: .prereleaseHandling) ?? .processEditable
        releaseYearRestoreThreshold = try container.decodeIfPresent(
            Int.self,
            forKey: .releaseYearRestoreThreshold
        ) ?? 5
        incrementalIntervalMinutes = try container.decodeIfPresent(Int.self, forKey: .incrementalIntervalMinutes) ?? 1
        minConfidenceToCache = try container.decodeIfPresent(Int.self, forKey: .minConfidenceToCache) ?? 50
        suspiciousAlbumMinLen = try container.decodeIfPresent(Int.self, forKey: .suspiciousAlbumMinLen) ?? 3
        suspiciousManyYears = try container.decodeIfPresent(Int.self, forKey: .suspiciousManyYears) ?? 3
    }
}

public enum PrereleaseHandling: String, Sendable, Codable, CaseIterable {
    case processEditable = "process_editable"
    case skipAll = "skip_all"
    case markOnly = "mark_only"
}

// MARK: - Cleaning Configuration

public struct CleaningConfig: Sendable, Codable, Equatable {
    // swiftlint:disable:next inclusive_language
    public var remasterKeywords: [String] = [
        "remaster", "remastered", "reissue", "expanded edition", "soundtrack",
        "original motion picture", "original score", "motion picture", "film score",
    ]
    public var albumSuffixesToRemove: [String] = [
        "Remaster", "Remastered", "The 12 Singles", "The 12\" Singles",
    ]
    public var trackCleaningExceptions: [TrackCleaningException] = []

    /// User-defined genre mappings applied after genre determination.
    ///
    /// Keys are source genres, values are replacement genres.
    /// Lookup is case-insensitive but the mapped value preserves its original case.
    /// Example: `{"Electronica": "Electronic", "Hip Hop": "Hip-Hop"}`
    public var genreMappings: [String: String] = [:]

    private enum CodingKeys: String, CodingKey {
        case editionKeywords = "remasterKeywords"
        case legacyEditionKeywords = "remaster_keywords"
        case albumSuffixesToRemove
        case legacyAlbumSuffixesToRemove = "album_suffixes_to_remove"
        case trackCleaningExceptions
        case legacyTrackCleaningExceptions = "track_cleaning"
        case genreMappings
        case legacyGenreMappings = "genre_mappings"
    }

    public init() {}

    public init(from decoder: any Decoder) throws {
        let defaults = Self()
        let container = try decoder.container(keyedBy: CodingKeys.self)

        remasterKeywords = try container.decodeIfPresent([String].self, forKey: .editionKeywords)
            ?? container.decodeIfPresent([String].self, forKey: .legacyEditionKeywords)
            ?? defaults.remasterKeywords
        albumSuffixesToRemove = try container.decodeIfPresent([String].self, forKey: .albumSuffixesToRemove)
            ?? container.decodeIfPresent([String].self, forKey: .legacyAlbumSuffixesToRemove)
            ?? defaults.albumSuffixesToRemove
        trackCleaningExceptions = try container.decodeIfPresent(
            [TrackCleaningException].self,
            forKey: .trackCleaningExceptions
        )
            ?? container.decodeIfPresent([TrackCleaningException].self, forKey: .legacyTrackCleaningExceptions)
            ?? defaults.trackCleaningExceptions
        genreMappings = try container.decodeIfPresent([String: String].self, forKey: .genreMappings)
            ?? container.decodeIfPresent([String: String].self, forKey: .legacyGenreMappings)
            ?? defaults.genreMappings
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(remasterKeywords, forKey: .editionKeywords)
        try container.encode(albumSuffixesToRemove, forKey: .albumSuffixesToRemove)
        try container.encode(trackCleaningExceptions, forKey: .trackCleaningExceptions)
        try container.encode(genreMappings, forKey: .genreMappings)
    }
}

public struct TrackCleaningException: Sendable, Codable, Equatable {
    public let artist: String
    public let album: String

    public init(artist: String, album: String) {
        self.artist = artist
        self.album = album
    }
}

// MARK: - Exceptions Configuration

public struct ExceptionsConfig: Sendable, Codable {
    public var trackCleaning: [TrackCleaningException] = []

    private enum CodingKeys: String, CodingKey {
        case trackCleaning
        case legacyTrackCleaning = "track_cleaning"
    }

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trackCleaning = try container.decodeIfPresent([TrackCleaningException].self, forKey: .trackCleaning)
            ?? container.decodeIfPresent([TrackCleaningException].self, forKey: .legacyTrackCleaning)
            ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(trackCleaning, forKey: .trackCleaning)
    }
}

// MARK: - Artist Renamer Configuration

public struct ArtistRenamerConfig: Sendable, Codable, Equatable {
    public var mappings: [String: String] = [:]

    private enum CodingKeys: String, CodingKey {
        case mappings
    }

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mappings = try container.decodeIfPresent([String: String].self, forKey: .mappings) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mappings, forKey: .mappings)
    }
}

// MARK: - Verification Configuration

public struct DatabaseVerificationConfig: Sendable, Codable {
    public var autoVerifyDays: Int = 7
    public var batchSize: Int = 10

    public init() {}
}

public struct PendingVerificationConfig: Sendable, Codable {
    public var autoVerifyDays: Int = 14

    public init() {}
}

// MARK: - Album Type Detection Configuration

public struct AlbumTypeDetectionConfig: Sendable, Codable, Equatable {
    public var specialPatterns: [String] = ["b-sides", "demo", "demos"]
    public var compilationPatterns: [String] = ["greatest hits", "best of", "compilation"]
    public var reissuePatterns: [String] = ["remaster", "remastered", "anniversary"]
    public var soundtrackPatterns: [String] = [
        "soundtrack", "original score", "OST", "motion picture", "film score",
    ]
    public var variousArtistsNames: [String] = [
        "Various Artists", "Various", "VA", "Різні виконавці",
    ]

    public init() {}
}

// MARK: - Experimental Configuration

public struct ExperimentalConfig: Sendable, Codable {
    public var batchUpdatesEnabled: Bool = false
    public var maxBatchSize: Int = 5

    public init() {}
}
