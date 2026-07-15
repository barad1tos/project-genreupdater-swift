import Core
import CryptoKit
import Foundation

/// Immutable configuration captured when a preview run is submitted.
public struct FixPlanConfig: Codable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    /// Captured runtime settings. Decoded snapshots redact auth references and must not construct API clients.
    public let appConfiguration: AppConfiguration
    public let updateGenre: Bool
    public let updateYear: Bool
    public let repairExistingGenreMismatches: Bool
    public let forceYearLookup: Bool
    public let cleanTrackNames: Bool
    public let cleanAlbumNames: Bool
    public let minConfidence: Int

    private let discogsReferenceDigest: String
    private let discogsCredentialRevision: String
    private let fingerprintValue: String

    public var fingerprint: String {
        fingerprintValue
    }

    public init(
        id: UUID = UUID(),
        capturedAt: Date,
        appConfiguration: AppConfiguration,
        options: UpdateOptions,
        discogsCredentialRevision: String = ""
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.appConfiguration = appConfiguration
        updateGenre = options.updateGenre
        updateYear = options.updateYear
        repairExistingGenreMismatches = options.repairExistingGenreMismatches
        forceYearLookup = options.forceYearLookup
        cleanTrackNames = options.cleanTrackNames
        cleanAlbumNames = options.cleanAlbumNames
        minConfidence = options.minConfidence
        let discogsReferenceDigest = digestDiscogsReference(appConfiguration)
        self.discogsReferenceDigest = discogsReferenceDigest
        self.discogsCredentialRevision = discogsCredentialRevision
        fingerprintValue = Self.makeFingerprint(
            configuration: appConfiguration,
            options: options,
            discogsReferenceDigest: discogsReferenceDigest,
            discogsCredentialRevision: discogsCredentialRevision
        )
    }

    public static func capture(
        configuration: AppConfiguration,
        options: UpdateOptions,
        capturedAt: Date,
        discogsCredentialRevision: String = ""
    ) -> Self {
        Self(
            capturedAt: capturedAt,
            appConfiguration: configuration,
            options: options,
            discogsCredentialRevision: discogsCredentialRevision
        )
    }

    /// Recreates determination inputs; write authority remains disabled.
    public var determinationOptions: UpdateOptions {
        UpdateOptions(
            updateGenre: updateGenre,
            updateYear: updateYear,
            repairExistingGenreMismatches: repairExistingGenreMismatches,
            forceYearLookup: forceYearLookup,
            cleanTrackNames: cleanTrackNames,
            cleanAlbumNames: cleanAlbumNames,
            minConfidence: minConfidence,
            autoAccept: false
        )
    }

    private static func makeFingerprint(
        configuration: AppConfiguration,
        options: UpdateOptions,
        discogsReferenceDigest: String,
        discogsCredentialRevision: String
    ) -> String {
        let input = FingerprintInput(
            configuration: configuration,
            options: options,
            discogsReferenceDigest: discogsReferenceDigest,
            discogsCredentialRevision: discogsCredentialRevision
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(input) else {
            preconditionFailure("Fix-plan configuration fingerprint encoding failed")
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private enum CodingKeys: String, CodingKey {
        case id, capturedAt, appConfiguration
        case updateGenre, updateYear, repairExistingGenreMismatches, forceYearLookup
        case cleanTrackNames, cleanAlbumNames, minConfidence
        case discogsReferenceDigest, discogsCredentialRevision, fingerprint
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        updateGenre = try container.decode(Bool.self, forKey: .updateGenre)
        updateYear = try container.decode(Bool.self, forKey: .updateYear)
        repairExistingGenreMismatches = try container.decode(Bool.self, forKey: .repairExistingGenreMismatches)
        forceYearLookup = try container.decode(Bool.self, forKey: .forceYearLookup)
        cleanTrackNames = try container.decode(Bool.self, forKey: .cleanTrackNames)
        cleanAlbumNames = try container.decode(Bool.self, forKey: .cleanAlbumNames)
        minConfidence = try container.decode(Int.self, forKey: .minConfidence)

        if let configuration = try container.decodeIfPresent(AppConfiguration.self, forKey: .appConfiguration) {
            appConfiguration = configuration
            discogsReferenceDigest = try container.decodeIfPresent(String.self, forKey: .discogsReferenceDigest)
                ?? digestDiscogsReference(configuration)
            discogsCredentialRevision = try container
                .decodeIfPresent(String.self, forKey: .discogsCredentialRevision) ?? ""
            fingerprintValue = Self.makeFingerprint(
                configuration: configuration,
                options: UpdateOptions(
                    updateGenre: updateGenre,
                    updateYear: updateYear,
                    repairExistingGenreMismatches: repairExistingGenreMismatches,
                    forceYearLookup: forceYearLookup,
                    cleanTrackNames: cleanTrackNames,
                    cleanAlbumNames: cleanAlbumNames,
                    minConfidence: minConfidence,
                    autoAccept: false
                ),
                discogsReferenceDigest: discogsReferenceDigest,
                discogsCredentialRevision: discogsCredentialRevision
            )
        } else {
            appConfiguration = AppConfiguration()
            discogsReferenceDigest = digestDiscogsReference(appConfiguration)
            discogsCredentialRevision = ""
            fingerprintValue = try container.decode(String.self, forKey: .fingerprint)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encode(redactedConfiguration(appConfiguration), forKey: .appConfiguration)
        try container.encode(updateGenre, forKey: .updateGenre)
        try container.encode(updateYear, forKey: .updateYear)
        try container.encode(repairExistingGenreMismatches, forKey: .repairExistingGenreMismatches)
        try container.encode(forceYearLookup, forKey: .forceYearLookup)
        try container.encode(cleanTrackNames, forKey: .cleanTrackNames)
        try container.encode(cleanAlbumNames, forKey: .cleanAlbumNames)
        try container.encode(minConfidence, forKey: .minConfidence)
        try container.encode(discogsReferenceDigest, forKey: .discogsReferenceDigest)
        try container.encode(discogsCredentialRevision, forKey: .discogsCredentialRevision)
        // Older readers consume this field; current readers recompute it when appConfiguration is present.
        try container.encode(fingerprint, forKey: .fingerprint)
    }
}

extension FixPlanConfig: Equatable {
    public static func == (left: Self, right: Self) -> Bool {
        left.id == right.id
            && left.capturedAt == right.capturedAt
            && left.fingerprint == right.fingerprint
    }
}

/// Configuration that can affect preview output or whether its dependencies complete successfully.
/// Keep this projection aligned with preview reads and determination. It excludes UI/diagnostic settings,
/// cache maintenance, write batching, automation schedules, and non-library paths.
private struct FingerprintInput: Encodable {
    let options: Options
    let discogsReferenceDigest: String
    let discogsCredentialRevision: String
    let runtime: Runtime
    let appleScript: AppleScript
    let yearRetrieval: YearRetrievalConfig
    let caching: Caching
    let processing: Processing
    let cleaning: CleaningConfig
    let exceptions: ExceptionsConfig
    let artistRenamer: ArtistRenamerConfig
    let genre: Genre
    let albumTypeDetection: AlbumTypeDetectionConfig
    let musicLibraryPath: String

    init(
        configuration: AppConfiguration,
        options: UpdateOptions,
        discogsReferenceDigest: String,
        discogsCredentialRevision: String
    ) {
        let configuration = redactedConfiguration(configuration)
        self.options = Options(options)
        self.discogsReferenceDigest = discogsReferenceDigest
        self.discogsCredentialRevision = discogsCredentialRevision
        runtime = Runtime(configuration.runtime)
        appleScript = AppleScript(configuration.applescript)
        yearRetrieval = configuration.yearRetrieval
        caching = Caching(configuration.caching)
        processing = Processing(configuration.processing)
        cleaning = configuration.cleaning
        exceptions = configuration.exceptions
        artistRenamer = configuration.artistRenamer
        genre = Genre(configuration.genreUpdate)
        albumTypeDetection = configuration.albumTypeDetection
        musicLibraryPath = configuration.paths.musicLibraryPath
    }

    struct Options: Encodable {
        let updateGenre: Bool
        let updateYear: Bool
        let repairExistingGenreMismatches: Bool
        let forceYearLookup: Bool
        let cleanTrackNames: Bool
        let cleanAlbumNames: Bool
        let minConfidence: Int

        init(_ options: UpdateOptions) {
            updateGenre = options.updateGenre
            updateYear = options.updateYear
            repairExistingGenreMismatches = options.repairExistingGenreMismatches
            forceYearLookup = options.forceYearLookup
            cleanTrackNames = options.cleanTrackNames
            cleanAlbumNames = options.cleanAlbumNames
            minConfidence = options.minConfidence
        }
    }

    struct Runtime: Encodable {
        let cacheTTLSeconds: Int
        let maxGenericEntries: Int
        let maxRetries: Int
        let retryDelaySeconds: Double

        init(_ runtime: RuntimeConfig) {
            cacheTTLSeconds = runtime.cacheTTLSeconds
            maxGenericEntries = runtime.maxGenericEntries
            maxRetries = runtime.maxRetries
            retryDelaySeconds = runtime.retryDelaySeconds
        }
    }

    struct AppleScript: Encodable {
        let concurrency: Int
        let timeouts: Timeouts
        let rateLimit: AppleScriptRateLimit
        let retry: AppleScriptRetry
        let batchProcessing: BatchProcessingConfig

        init(_ configuration: AppleScriptConfig) {
            concurrency = configuration.concurrency
            timeouts = Timeouts(configuration.timeouts)
            rateLimit = configuration.rateLimit
            retry = configuration.retry
            batchProcessing = configuration.batchProcessing
        }

        struct Timeouts: Encodable {
            let defaultSeconds: Int
            let fullLibraryFetchSeconds: Int
            let singleArtistFetchSeconds: Int
            let idsBatchFetchSeconds: Int

            init(_ timeouts: AppleScriptTimeouts) {
                defaultSeconds = Int(timeouts.defaultTimeout.timeInterval)
                fullLibraryFetchSeconds = Int(timeouts.fullLibraryFetch.timeInterval)
                singleArtistFetchSeconds = Int(timeouts.singleArtistFetch.timeInterval)
                idsBatchFetchSeconds = Int(timeouts.idsBatchFetch.timeInterval)
            }
        }
    }

    struct Caching: Encodable {
        let defaultTTLSeconds: Int
        let negativeResultTTL: Double
        let snapshot: Snapshot

        init(_ caching: CachingConfig) {
            defaultTTLSeconds = caching.defaultTTLSeconds
            negativeResultTTL = caching.negativeResultTTL
            snapshot = Snapshot(caching.librarySnapshot)
        }

        struct Snapshot: Encodable {
            let enabled: Bool
            let deltaEnabled: Bool
            let cacheFile: String
            let maxAgeHours: Int

            init(_ snapshot: LibrarySnapshotConfig) {
                enabled = snapshot.enabled
                deltaEnabled = snapshot.deltaEnabled
                cacheFile = snapshot.cacheFile
                maxAgeHours = snapshot.maxAgeHours
            }
        }
    }

    struct Processing: Encodable {
        let cacheTTLDays: Int
        let pendingVerificationIntervalDays: Int
        let skipPrerelease: Bool
        let futureYearThreshold: Int
        let prereleaseRecheckDays: Int
        let prereleaseHandling: PrereleaseHandling
        let minConfidenceToCache: Int
        let suspiciousAlbumMinLen: Int
        let suspiciousManyYears: Int

        init(_ processing: ProcessingConfig) {
            cacheTTLDays = processing.cacheTTLDays
            pendingVerificationIntervalDays = processing.pendingVerificationIntervalDays
            skipPrerelease = processing.skipPrerelease
            futureYearThreshold = processing.futureYearThreshold
            prereleaseRecheckDays = processing.prereleaseRecheckDays
            prereleaseHandling = processing.prereleaseHandling
            minConfidenceToCache = processing.minConfidenceToCache
            suspiciousAlbumMinLen = processing.suspiciousAlbumMinLen
            suspiciousManyYears = processing.suspiciousManyYears
        }
    }

    struct Genre: Encodable {
        let overrideExisting: Bool

        init(_ genre: GenreUpdateConfig) {
            overrideExisting = genre.overrideExisting
        }
    }
}

private func digestDiscogsReference(_ configuration: AppConfiguration) -> String {
    let reference = configuration.yearRetrieval.apiAuth.discogsTokenReference
    return SHA256.hash(data: Data(reference.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func redactedConfiguration(_ configuration: AppConfiguration) -> AppConfiguration {
    var redacted = configuration
    redacted.yearRetrieval.apiAuth.discogsTokenReference = ""
    // Contact email identifies API requests but cannot change preview output, so it stays outside the fingerprint.
    redacted.yearRetrieval.apiAuth.contactEmailReference = ""
    return redacted
}
