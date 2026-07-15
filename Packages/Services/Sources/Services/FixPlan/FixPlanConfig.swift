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
    private let fingerprintValue: String

    public var fingerprint: String {
        fingerprintValue
    }

    public init(
        id: UUID = UUID(),
        capturedAt: Date,
        appConfiguration: AppConfiguration,
        options: UpdateOptions
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
        fingerprintValue = Self.makeFingerprint(
            configuration: appConfiguration,
            options: options,
            discogsReferenceDigest: discogsReferenceDigest
        )
    }

    public static func capture(
        configuration: AppConfiguration,
        options: UpdateOptions,
        capturedAt: Date
    ) -> Self {
        Self(
            capturedAt: capturedAt,
            appConfiguration: configuration,
            options: options
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
        discogsReferenceDigest: String
    ) -> String {
        let input = FingerprintInput(
            configuration: configuration,
            options: options,
            discogsReferenceDigest: discogsReferenceDigest
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
        case cleanTrackNames, cleanAlbumNames, minConfidence, discogsReferenceDigest, fingerprint
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
                discogsReferenceDigest: discogsReferenceDigest
            )
        } else {
            appConfiguration = AppConfiguration()
            discogsReferenceDigest = digestDiscogsReference(appConfiguration)
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
/// Keep this projection aligned with `AppConfiguration`. It deliberately excludes UI/diagnostic-only
/// sections: pythonSettings, analytics, databaseVerification, reporting, logging, development, and
/// non-library paths.
private struct FingerprintInput: Encodable {
    let options: Options
    let discogsReferenceDigest: String
    let runtime: Runtime
    let appleScript: AppleScriptConfig
    let yearRetrieval: YearRetrievalConfig
    let caching: CachingConfig
    let processing: ProcessingConfig
    let cleaning: CleaningConfig
    let exceptions: ExceptionsConfig
    let artistRenamer: ArtistRenamerConfig
    let genreUpdate: GenreUpdateConfig
    let albumTypeDetection: AlbumTypeDetectionConfig
    let experimental: ExperimentalConfig
    let pendingVerification: PendingVerificationConfig
    let musicLibraryPath: String

    init(
        configuration: AppConfiguration,
        options: UpdateOptions,
        discogsReferenceDigest: String
    ) {
        let configuration = redactedConfiguration(configuration)
        self.options = Options(options)
        self.discogsReferenceDigest = discogsReferenceDigest
        runtime = Runtime(configuration.runtime)
        appleScript = configuration.applescript
        yearRetrieval = configuration.yearRetrieval
        caching = configuration.caching
        processing = configuration.processing
        cleaning = configuration.cleaning
        exceptions = configuration.exceptions
        artistRenamer = configuration.artistRenamer
        genreUpdate = configuration.genreUpdate
        albumTypeDetection = configuration.albumTypeDetection
        experimental = configuration.experimental
        pendingVerification = configuration.pendingVerification
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
