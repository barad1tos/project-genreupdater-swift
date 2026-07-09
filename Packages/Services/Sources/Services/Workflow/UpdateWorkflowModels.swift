import Core

/// Result of a multi-track update.
///
/// Applied entries represent recorded metadata writes. No-op entries represent
/// verified write attempts that left Music.app metadata unchanged. Failures
/// capture processing/write operations that could not be completed. The same
/// track ID may appear more than once when multiple writes fail on one track.
public struct BatchUpdateResult: Sendable {
    public let entries: [ChangeLogEntry]
    public let noOpEntries: [ChangeLogEntry]
    public let failedTrackIDs: [String]
    public let errorDescriptions: [String]

    public init(
        entries: [ChangeLogEntry],
        noOpEntries: [ChangeLogEntry] = [],
        failedTrackIDs: [String],
        errorDescriptions: [String]
    ) {
        self.entries = entries
        self.noOpEntries = noOpEntries
        self.failedTrackIDs = failedTrackIDs
        self.errorDescriptions = errorDescriptions
    }

    public var hasPartialFailures: Bool {
        !failedTrackIDs.isEmpty && (!entries.isEmpty || !noOpEntries.isEmpty)
    }

    public var appliedOperationCount: Int {
        entries.count
    }

    public var updatedTrackCount: Int {
        Set(entries.map(\.trackID)).count
    }

    public var failedOperationCount: Int {
        failedTrackIDs.count
    }

    public var failedTrackCount: Int {
        Set(failedTrackIDs).count
    }
}

/// Result of resolving and applying a pending album verification.
public struct PendingAlbumVerificationResult: Sendable {
    public let entries: [ChangeLogEntry]
    public let resolvedYear: Int?
    public let unchangedTrackIDs: [String]
    public let failedTrackIDs: [String]
    public let errorDescriptions: [String]
    public let canClearPendingEntry: Bool

    public init(
        entries: [ChangeLogEntry],
        resolvedYear: Int?,
        unchangedTrackIDs: [String] = [],
        failedTrackIDs: [String] = [],
        errorDescriptions: [String] = [],
        canClearPendingEntry: Bool = false
    ) {
        self.entries = entries
        self.resolvedYear = resolvedYear
        self.unchangedTrackIDs = unchangedTrackIDs
        self.failedTrackIDs = failedTrackIDs
        self.errorDescriptions = errorDescriptions
        self.canClearPendingEntry = canClearPendingEntry
    }

    public var didResolveYear: Bool {
        resolvedYear != nil
    }

    public var hasFailures: Bool {
        !failedTrackIDs.isEmpty
    }
}

/// Configuration for an update operation.
public struct UpdateOptions: Sendable {
    public let updateGenre: Bool
    public let updateYear: Bool
    public let repairExistingGenreMismatches: Bool
    public let forceYearLookup: Bool
    public let cleanTrackNames: Bool
    public let cleanAlbumNames: Bool
    public let minConfidence: Int
    public let autoAccept: Bool

    public init(
        updateGenre: Bool = true,
        updateYear: Bool = true,
        repairExistingGenreMismatches: Bool = false,
        forceYearLookup: Bool = false,
        cleanTrackNames: Bool = false,
        cleanAlbumNames: Bool = false,
        minConfidence: Int = 60,
        autoAccept: Bool = false
    ) {
        self.updateGenre = updateGenre
        self.updateYear = updateYear
        self.repairExistingGenreMismatches = repairExistingGenreMismatches
        self.forceYearLookup = forceYearLookup
        self.cleanTrackNames = cleanTrackNames
        self.cleanAlbumNames = cleanAlbumNames
        self.minConfidence = minConfidence
        self.autoAccept = autoAccept
    }

    /// Returns the workflow confidence threshold as a rounded percentage.
    public static func clampedConfidencePercent(fromRatio confidence: Double) -> Int {
        Int((clampedConfidenceRatio(confidence) * 100).rounded())
    }

    /// Clamps confidence to the workflow-supported 0.3...1.0 range.
    ///
    /// The floor preserves the app's minimum accepted year-lookup confidence; the ceiling is the natural ratio maximum.
    public static func clampedConfidenceRatio(_ confidence: Double) -> Double {
        min(max(confidence, 0.3), 1.0)
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
    public let areBatchUpdatesEnabled: Bool
    public let maxBatchUpdateSize: Int
    public let idsBatchSize: Int

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
        areBatchUpdatesEnabled: Bool = AppConfiguration().experimental.batchUpdatesEnabled,
        maxBatchUpdateSize: Int = AppConfiguration().experimental.maxBatchSize,
        idsBatchSize: Int = BatchProcessingConfig().idsBatchSize,
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
        self.areBatchUpdatesEnabled = areBatchUpdatesEnabled
        self.maxBatchUpdateSize = max(1, maxBatchUpdateSize)
        self.idsBatchSize = max(1, idsBatchSize)
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
            areBatchUpdatesEnabled: configuration.experimental.batchUpdatesEnabled,
            maxBatchUpdateSize: configuration.experimental.maxBatchSize,
            idsBatchSize: configuration.applescript.batchProcessing.idsBatchSize,
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
