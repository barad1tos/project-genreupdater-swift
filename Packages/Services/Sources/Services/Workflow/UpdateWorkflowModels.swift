import Core

/// Result of a multi-track update, exposing both successes and failures.
public struct BatchUpdateResult: Sendable {
    public let entries: [ChangeLogEntry]
    public let failedTrackIDs: [String]
    public let errorDescriptions: [String]

    public init(
        entries: [ChangeLogEntry],
        failedTrackIDs: [String],
        errorDescriptions: [String]
    ) {
        self.entries = entries
        self.failedTrackIDs = failedTrackIDs
        self.errorDescriptions = errorDescriptions
    }

    public var hasPartialFailures: Bool {
        !failedTrackIDs.isEmpty && !entries.isEmpty
    }
}

/// Result of resolving and applying a pending album verification.
public struct PendingAlbumVerificationResult: Sendable {
    public let entries: [ChangeLogEntry]
    public let resolvedYear: Int?

    public var didResolveYear: Bool {
        resolvedYear != nil
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
    public let artistRenameMappings: [String: String]
    public let isYearLookupEnabled: Bool
    public let minimumYearUpdateConfidence: Double
    public let minimumConfidenceToCache: Int
    public let albumTypeDetection: AlbumTypeDetectionConfig
    public let cleaning: CleaningConfig
    public let skipPrerelease: Bool
    public let prereleaseHandling: PrereleaseHandling
    public let prereleaseRecheckDays: Int
    /// Artist allow-list for update writes; empty means all effective artists are allowed.
    public let testArtists: [String]
    public let shouldOverrideExistingGenres: Bool

    public struct Policies: Sendable, Equatable {
        public let isYearLookupEnabled: Bool
        public let minimumYearUpdateConfidence: Double
        public let minimumConfidenceToCache: Int
        public let albumTypeDetection: AlbumTypeDetectionConfig
        public let cleaning: CleaningConfig
        public let skipPrerelease: Bool
        public let prereleaseHandling: PrereleaseHandling
        public let prereleaseRecheckDays: Int
        public let shouldOverrideExistingGenres: Bool

        public init(
            isYearLookupEnabled: Bool = AppConfiguration().yearRetrieval.enabled,
            minimumYearUpdateConfidence: Double = AppConfiguration().yearRetrieval.logic.minConfidenceForNewYear,
            minimumConfidenceToCache: Int = AppConfiguration().processing.minConfidenceToCache,
            albumTypeDetection: AlbumTypeDetectionConfig = AlbumTypeDetectionConfig(),
            cleaning: CleaningConfig = CleaningConfig(),
            skipPrerelease: Bool = AppConfiguration().processing.skipPrerelease,
            prereleaseHandling: PrereleaseHandling = AppConfiguration().processing.prereleaseHandling,
            prereleaseRecheckDays: Int = AppConfiguration().processing.prereleaseRecheckDays,
            shouldOverrideExistingGenres: Bool = AppConfiguration().genreUpdate.overrideExisting
        ) {
            self.isYearLookupEnabled = isYearLookupEnabled
            self.minimumYearUpdateConfidence = minimumYearUpdateConfidence
            self.minimumConfidenceToCache = minimumConfidenceToCache
            self.albumTypeDetection = albumTypeDetection
            self.cleaning = cleaning
            self.skipPrerelease = skipPrerelease
            self.prereleaseHandling = prereleaseHandling
            self.prereleaseRecheckDays = prereleaseRecheckDays
            self.shouldOverrideExistingGenres = shouldOverrideExistingGenres
        }
    }

    public init(
        genreMappings: [String: String] = [:],
        artistRenameMappings: [String: String] = [:],
        testArtists: [String] = AppConfiguration().development.testArtists,
        policies: Policies = Policies()
    ) {
        self.genreMappings = genreMappings
        self.artistRenameMappings = Self.normalizedMappings(artistRenameMappings)
        self.isYearLookupEnabled = policies.isYearLookupEnabled
        self.minimumYearUpdateConfidence = policies.minimumYearUpdateConfidence
        self.minimumConfidenceToCache = policies.minimumConfidenceToCache
        self.albumTypeDetection = policies.albumTypeDetection
        self.cleaning = policies.cleaning
        self.skipPrerelease = policies.skipPrerelease
        self.prereleaseHandling = policies.prereleaseHandling
        self.prereleaseRecheckDays = policies.prereleaseRecheckDays
        self.testArtists = testArtists
        self.shouldOverrideExistingGenres = policies.shouldOverrideExistingGenres
    }

    public init(configuration: AppConfiguration) {
        var cleaning = configuration.cleaning
        cleaning.trackCleaningExceptions = Self.mergeTrackCleaningExceptions(
            cleaning.trackCleaningExceptions,
            configuration.exceptions.trackCleaning
        )

        self.init(
            genreMappings: configuration.cleaning.genreMappings,
            artistRenameMappings: configuration.artistRenamer.mappings,
            testArtists: configuration.development.testArtists,
            policies: Policies(
                isYearLookupEnabled: configuration.yearRetrieval.enabled,
                minimumYearUpdateConfidence: configuration.yearRetrieval.logic.minConfidenceForNewYear,
                minimumConfidenceToCache: configuration.processing.minConfidenceToCache,
                albumTypeDetection: configuration.albumTypeDetection,
                cleaning: cleaning,
                skipPrerelease: configuration.processing.skipPrerelease,
                prereleaseHandling: configuration.processing.prereleaseHandling,
                prereleaseRecheckDays: configuration.processing.prereleaseRecheckDays,
                shouldOverrideExistingGenres: configuration.genreUpdate.overrideExisting
            )
        )
    }

    func allowsTrack(_ track: Track) -> Bool {
        ArtistAllowList.contains(track, in: testArtists)
    }

    func allowsChange(_ change: ProposedChange) -> Bool {
        if allowsTrack(change.track) {
            return true
        }

        guard change.changeType == .artistRename,
              let originalArtist = change.oldValue
        else {
            return false
        }
        return ArtistAllowList.contains(originalArtist, in: testArtists)
    }

    private static func normalizedMappings(_ mappings: [String: String]) -> [String: String] {
        var normalized: [String: String] = [:]

        for (source, target) in mappings {
            let key = normalizeForMatching(source)
            let value = target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { continue }
            normalized[key] = value
        }

        return normalized
    }

    private static func mergeTrackCleaningExceptions(
        _ canonical: [TrackCleaningException],
        _ legacy: [TrackCleaningException]
    ) -> [TrackCleaningException] {
        var seen: Set<String> = []
        var merged: [TrackCleaningException] = []

        for exception in canonical + legacy {
            let key = [
                exception.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                exception.album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            ].joined(separator: "\u{1F}")
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            merged.append(exception)
        }

        return merged
    }
}
