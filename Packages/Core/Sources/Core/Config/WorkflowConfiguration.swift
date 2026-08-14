// WorkflowConfiguration.swift — metadata, verification, and workflow configuration.

import Foundation

// MARK: - Genre Update Configuration

public struct GenreUpdateConfig: Sendable, Codable {
    public var batchSize: Int = 50
    public var concurrentLimit: Int = 5
    public var overrideExisting: Bool = false

    private enum CodingKeys: String, CodingKey {
        case batchSize, concurrentLimit, overrideExisting
    }

    public init() { /* memberwise defaults are the whole initial state */ }

    public init(from decoder: any Decoder) throws {
        let defaults = Self()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        batchSize = try container.decodeIfPresent(Int.self, forKey: .batchSize) ?? defaults.batchSize
        concurrentLimit = try container.decodeIfPresent(Int.self, forKey: .concurrentLimit) ?? defaults.concurrentLimit
        overrideExisting = try container.decodeIfPresent(Bool.self, forKey: .overrideExisting)
            ?? defaults.overrideExisting
    }
}

// MARK: - Update Behavior

/// Which metadata targets a default run updates. Persisted in
/// `ProcessingConfig`; raw values are shared with the DesignUI mirror.
public enum UpdateBehavior: String, Sendable, Codable, CaseIterable, Identifiable {
    case genreOnly = "genre_only"
    case yearOnly = "year_only"
    case both

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .genreOnly: "Genre only"
        case .yearOnly: "Year only"
        case .both: "Both"
        }
    }

    public var enabledTargets: (updateGenre: Bool, updateYear: Bool) {
        switch self {
        case .genreOnly:
            (true, false)
        case .yearOnly:
            (false, true)
        case .both:
            (true, true)
        }
    }

    public static func resolved(from rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .both
    }
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
    public var minConfidenceToCache: Int = 50
    public var suspiciousAlbumMinLen: Int = 3
    public var suspiciousManyYears: Int = 3
    public var defaultUpdateBehavior: UpdateBehavior = .both

    private enum CodingKeys: String, CodingKey {
        case batchSize, delayBetweenBatches, adaptiveDelay, cacheTTLDays, pendingVerificationIntervalDays
        case skipPrerelease, futureYearThreshold, prereleaseRecheckDays, prereleaseHandling
        case releaseYearRestoreThreshold, minConfidenceToCache, suspiciousAlbumMinLen
        case suspiciousManyYears, defaultUpdateBehavior
    }

    private enum DecodingKeys: String, CodingKey {
        case batchSize, delayBetweenBatches, adaptiveDelay, cacheTTLDays, pendingVerificationIntervalDays
        case skipPrerelease, futureYearThreshold, prereleaseRecheckDays, prereleaseHandling
        case releaseYearRestoreThreshold, minConfidenceToCache, suspiciousAlbumMinLen
        case suspiciousManyYears, defaultUpdateBehavior
        case cacheTtlDays
    }

    public init() { /* memberwise defaults are the whole initial state */ }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DecodingKeys.self)
        batchSize = try container.decodeIfPresent(Int.self, forKey: .batchSize) ?? 25
        delayBetweenBatches = try container.decodeIfPresent(Double.self, forKey: .delayBetweenBatches) ?? 20
        adaptiveDelay = try container.decodeIfPresent(Bool.self, forKey: .adaptiveDelay) ?? true
        cacheTTLDays = try container.decodeIfPresent(Int.self, forKey: .cacheTTLDays)
            ?? container.decodeIfPresent(Int.self, forKey: .cacheTtlDays)
            ?? 36500
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
        minConfidenceToCache = try container.decodeIfPresent(Int.self, forKey: .minConfidenceToCache) ?? 50
        suspiciousAlbumMinLen = try container.decodeIfPresent(Int.self, forKey: .suspiciousAlbumMinLen) ?? 3
        suspiciousManyYears = try container.decodeIfPresent(Int.self, forKey: .suspiciousManyYears) ?? 3
        defaultUpdateBehavior = try container
            .decodeIfPresent(UpdateBehavior.self, forKey: .defaultUpdateBehavior) ?? .both
    }
}

public enum PrereleaseHandling: String, Sendable, Codable, CaseIterable {
    case processEditable = "process_editable"
    case skipAll = "skip_all"
    case markOnly = "mark_only"
}

// MARK: - Cleaning Configuration

public struct CleaningConfig: Sendable, Codable, Equatable {
    public var editionMarkers: [String] = MetadataRuleDefaults.editionMarkers
    public var albumSuffixes: [String] = MetadataRuleDefaults.albumSuffixes
    public var trackCleaningExceptions: [TrackCleaningException] = []

    /// User-defined genre mappings applied after genre determination.
    ///
    /// Keys are source genres, values are replacement genres.
    /// Lookup is case-insensitive but the mapped value preserves its original case.
    /// Example: `{"Electronica": "Electronic", "Hip Hop": "Hip-Hop"}`
    public var genreMappings: [String: String] = [:]

    private enum CodingKeys: String, CodingKey {
        case editionMarkers
        case legacyEditionMarkers = "remasterKeywords"
        case pythonEditionMarkers = "remaster_keywords"
        case albumSuffixes
        case legacyAlbumSuffixes = "albumSuffixesToRemove"
        case pythonAlbumSuffixes = "album_suffixes_to_remove"
        case trackCleaningExceptions
        case trackCleaning
        case legacyTrackCleaningExceptions = "track_cleaning"
        case genreMappings
        case legacyGenreMappings = "genre_mappings"
    }

    public init() { /* memberwise defaults are the whole initial state */ }

    public init(from decoder: any Decoder) throws {
        let defaults = Self()
        let container = try decoder.container(keyedBy: CodingKeys.self)

        editionMarkers = try container.decodeIfPresent([String].self, forKey: .editionMarkers)
            ?? container.decodeIfPresent([String].self, forKey: .legacyEditionMarkers)
            ?? container.decodeIfPresent([String].self, forKey: .pythonEditionMarkers)
            ?? defaults.editionMarkers
        albumSuffixes = try container.decodeIfPresent([String].self, forKey: .albumSuffixes)
            ?? container.decodeIfPresent([String].self, forKey: .legacyAlbumSuffixes)
            ?? container.decodeIfPresent([String].self, forKey: .pythonAlbumSuffixes)
            ?? defaults.albumSuffixes
        trackCleaningExceptions = try container.decodeIfPresent(
            [TrackCleaningException].self,
            forKey: .trackCleaningExceptions
        )
            ?? container.decodeIfPresent([TrackCleaningException].self, forKey: .trackCleaning)
            ?? container.decodeIfPresent([TrackCleaningException].self, forKey: .legacyTrackCleaningExceptions)
            ?? defaults.trackCleaningExceptions
        genreMappings = try container.decodeIfPresent([String: String].self, forKey: .genreMappings)
            ?? container.decodeIfPresent([String: String].self, forKey: .legacyGenreMappings)
            ?? defaults.genreMappings
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(editionMarkers, forKey: .editionMarkers)
        try container.encode(albumSuffixes, forKey: .albumSuffixes)
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

    public init() { /* memberwise defaults are the whole initial state */ }

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

    public init() { /* memberwise defaults are the whole initial state */ }

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

    public init() { /* memberwise defaults are the whole initial state */ }
}

public struct PendingVerificationConfig: Sendable, Codable {
    public var autoVerifyDays: Int = 14

    public init() { /* memberwise defaults are the whole initial state */ }
}

// MARK: - Album Type Detection Configuration

public struct AlbumTypeDetectionConfig: Sendable, Codable, Equatable {
    public var specialPatterns: [String] = MetadataRuleDefaults.specialAlbums
    public var compilationPatterns: [String] = MetadataRuleDefaults.compilations
    public var reissuePatterns: [String] = MetadataRuleDefaults.reissues
    public var soundtrackPatterns: [String] = MetadataRuleDefaults.soundtracks
    public var variousArtistsNames: [String] = MetadataRuleDefaults.variousArtists

    public init() { /* memberwise defaults are the whole initial state */ }
}

// MARK: - Experimental Configuration

public struct ExperimentalConfig: Sendable, Codable {
    public var batchUpdatesEnabled: Bool = false
    public var maxBatchSize: Int = 5

    public init() { /* memberwise defaults are the whole initial state */ }
}
