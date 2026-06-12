import Core

/// Result of a multi-track update, exposing both successes and failures.
public struct BatchUpdateResult: Sendable {
    public let entries: [ChangeLogEntry]
    public let failedTrackIDs: [String]
    public let errorDescriptions: [String]

    public var hasPartialFailures: Bool {
        !failedTrackIDs.isEmpty && !entries.isEmpty
    }
}

/// Configuration for an update operation.
public struct UpdateOptions: Sendable {
    public let updateGenre: Bool
    public let updateYear: Bool
    public let cleanTrackNames: Bool
    public let cleanAlbumNames: Bool
    public let minConfidence: Int
    public let autoAccept: Bool

    public init(
        updateGenre: Bool = true,
        updateYear: Bool = true,
        cleanTrackNames: Bool = false,
        cleanAlbumNames: Bool = false,
        minConfidence: Int = 60,
        autoAccept: Bool = false
    ) {
        self.updateGenre = updateGenre
        self.updateYear = updateYear
        self.cleanTrackNames = cleanTrackNames
        self.cleanAlbumNames = cleanAlbumNames
        self.minConfidence = minConfidence
        self.autoAccept = autoAccept
    }
}

/// Runtime configuration applied by update workflows.
public struct UpdateRuntimeConfiguration: Sendable, Equatable {
    public let genreMappings: [String: String]
    public let isYearLookupEnabled: Bool
    public let minimumYearUpdateConfidence: Double
    public let minimumConfidenceToCache: Int
    public let albumTypeDetection: AlbumTypeDetectionConfig
    public let cleaning: CleaningConfig
    public let shouldOverrideExistingGenres: Bool

    public init(
        genreMappings: [String: String] = [:],
        isYearLookupEnabled: Bool = AppConfiguration().yearRetrieval.enabled,
        minimumYearUpdateConfidence: Double = AppConfiguration().yearRetrieval.logic.minConfidenceForNewYear,
        minimumConfidenceToCache: Int = AppConfiguration().processing.minConfidenceToCache,
        albumTypeDetection: AlbumTypeDetectionConfig = AlbumTypeDetectionConfig(),
        cleaning: CleaningConfig = CleaningConfig(),
        shouldOverrideExistingGenres: Bool = AppConfiguration().genreUpdate.overrideExisting
    ) {
        self.genreMappings = genreMappings
        self.isYearLookupEnabled = isYearLookupEnabled
        self.minimumYearUpdateConfidence = minimumYearUpdateConfidence
        self.minimumConfidenceToCache = minimumConfidenceToCache
        self.albumTypeDetection = albumTypeDetection
        self.cleaning = cleaning
        self.shouldOverrideExistingGenres = shouldOverrideExistingGenres
    }

    public init(configuration: AppConfiguration) {
        self.init(
            genreMappings: configuration.cleaning.genreMappings,
            isYearLookupEnabled: configuration.yearRetrieval.enabled,
            minimumYearUpdateConfidence: configuration.yearRetrieval.logic.minConfidenceForNewYear,
            minimumConfidenceToCache: configuration.processing.minConfidenceToCache,
            albumTypeDetection: configuration.albumTypeDetection,
            cleaning: configuration.cleaning,
            shouldOverrideExistingGenres: configuration.genreUpdate.overrideExisting
        )
    }
}
