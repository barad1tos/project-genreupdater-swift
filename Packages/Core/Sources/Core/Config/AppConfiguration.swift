// AppConfiguration.swift — Application configuration model
// Ported from: src/core/core_config.py (325 LOC) + track_models.py config models (400 LOC)
//
// Key differences from Python:
// - Codable replaces Pydantic BaseModel (compiler-synthesized conformance)
// - @AppStorage used in Views for persisted preferences
// - Keychain for API keys (not config file)
// - Config stored as JSON in app container
// - Environment variable resolution not needed (GUI app, not CLI)
// - Validation via Swift's type system + throwing init where needed

import Foundation

// MARK: - Main Configuration

/// Root configuration for Genre Updater.
///
/// In the macOS app, configuration is managed through:
/// - Settings UI → @AppStorage (user preferences)
/// - Keychain → API keys (secure storage)
/// - This struct → serialized as JSON in app container (detailed settings)
///
/// Python CLI configuration values are represented as Codable Swift settings.
/// Runtime secrets are stored in Keychain.
public struct AppConfiguration: Sendable, Codable {
    public var paths = PathsConfig()
    public var pythonSettings = PythonSettingsConfig()
    public var runtime = RuntimeConfig()
    public var applescript = AppleScriptConfig()
    public var yearRetrieval = YearRetrievalConfig()
    public var genreUpdate = GenreUpdateConfig()
    public var caching = CachingConfig()
    public var processing = ProcessingConfig()
    public var analytics = AnalyticsConfig()
    public var cleaning = CleaningConfig()
    public var exceptions = ExceptionsConfig()
    public var artistRenamer = ArtistRenamerConfig()
    public var databaseVerification = DatabaseVerificationConfig()
    public var pendingVerification = PendingVerificationConfig()
    public var reporting = ReportingConfig()
    public var logging = LoggingConfig()
    public var albumTypeDetection = AlbumTypeDetectionConfig()
    public var experimental = ExperimentalConfig()
    public var development = DevelopmentConfig()

    private enum CodingKeys: String, CodingKey {
        case paths, pythonSettings, runtime, applescript, yearRetrieval, genreUpdate, caching
        case processing, analytics, cleaning, exceptions, artistRenamer, databaseVerification
        case pendingVerification, reporting, logging
        case albumTypeDetection, experimental, development
    }

    private enum DecodingKeys: String, CodingKey {
        case paths, pythonSettings, runtime, applescript, yearRetrieval, genreUpdate, caching
        case processing, analytics, cleaning, exceptions, artistRenamer, databaseVerification
        case pendingVerification, reporting, logging
        case albumTypeDetection, experimental, development

        case musicLibraryPath, appleScriptsDirectory, logsBaseDirectory, apiCacheFile
        case appleScriptsDir, logsBaseDir
        case dryRun, cacheTTLSeconds, incrementalIntervalMinutes, maxRetries, retryDelaySeconds, maxGenericEntries
        case cacheTtlSeconds
        case appleScriptConcurrency, appleScriptRateLimit, applescriptTimeoutSeconds
        case applescriptTimeouts, applescriptRetry, batchProcessing
        case testArtists
    }

    private enum YearRetrievalDecodingKeys: String, CodingKey {
        case processing
    }

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DecodingKeys.self)
        paths = try container.decodeIfPresent(PathsConfig.self, forKey: .paths) ?? PathsConfig()
        pythonSettings = try container
            .decodeIfPresent(PythonSettingsConfig.self, forKey: .pythonSettings) ?? PythonSettingsConfig()
        runtime = try container.decodeIfPresent(RuntimeConfig.self, forKey: .runtime) ?? RuntimeConfig()
        applescript = try container.decodeIfPresent(AppleScriptConfig.self, forKey: .applescript) ?? AppleScriptConfig()
        yearRetrieval = try container
            .decodeIfPresent(YearRetrievalConfig.self, forKey: .yearRetrieval) ?? YearRetrievalConfig()
        genreUpdate = try container.decodeIfPresent(GenreUpdateConfig.self, forKey: .genreUpdate) ?? GenreUpdateConfig()
        caching = try container.decodeIfPresent(CachingConfig.self, forKey: .caching) ?? CachingConfig()
        processing = try container.decodeIfPresent(ProcessingConfig.self, forKey: .processing) ?? ProcessingConfig()
        analytics = try container.decodeIfPresent(AnalyticsConfig.self, forKey: .analytics) ?? AnalyticsConfig()
        cleaning = try container.decodeIfPresent(CleaningConfig.self, forKey: .cleaning) ?? CleaningConfig()
        exceptions = try container.decodeIfPresent(ExceptionsConfig.self, forKey: .exceptions) ?? ExceptionsConfig()
        if cleaning.trackCleaningExceptions.isEmpty, !exceptions.trackCleaning.isEmpty {
            cleaning.trackCleaningExceptions = exceptions.trackCleaning
        }
        artistRenamer = try container
            .decodeIfPresent(ArtistRenamerConfig.self, forKey: .artistRenamer) ?? ArtistRenamerConfig()
        databaseVerification = try container.decodeIfPresent(
            DatabaseVerificationConfig.self,
            forKey: .databaseVerification
        ) ?? DatabaseVerificationConfig()
        pendingVerification = try container.decodeIfPresent(
            PendingVerificationConfig.self,
            forKey: .pendingVerification
        ) ?? PendingVerificationConfig()
        reporting = try container.decodeIfPresent(ReportingConfig.self, forKey: .reporting) ?? ReportingConfig()
        logging = try container.decodeIfPresent(LoggingConfig.self, forKey: .logging) ?? LoggingConfig()
        albumTypeDetection = try container
            .decodeIfPresent(AlbumTypeDetectionConfig.self, forKey: .albumTypeDetection) ?? AlbumTypeDetectionConfig()
        experimental = try container
            .decodeIfPresent(ExperimentalConfig.self, forKey: .experimental) ?? ExperimentalConfig()
        development = try container.decodeIfPresent(DevelopmentConfig.self, forKey: .development) ?? DevelopmentConfig()

        try applyLegacyRootConfiguration(from: container)
    }

    private mutating func applyLegacyRootConfiguration(
        from container: KeyedDecodingContainer<DecodingKeys>
    ) throws {
        try applyLegacyPathConfiguration(from: container)
        try applyLegacyRuntimeConfiguration(from: container)
        try applyLegacyAppleScriptConfiguration(from: container)
        try applyLegacyProcessingConfiguration(from: container)
        try applyLegacyDevelopmentConfiguration(from: container)
    }

    private mutating func applyLegacyPathConfiguration(
        from container: KeyedDecodingContainer<DecodingKeys>
    ) throws {
        if let musicLibraryPath = try container.decodeIfPresent(String.self, forKey: .musicLibraryPath) {
            paths.musicLibraryPath = musicLibraryPath
        }
        if let appleScriptsDirectory = try container.decodeIfPresent(String.self, forKey: .appleScriptsDirectory) {
            paths.appleScriptsDirectory = appleScriptsDirectory
        } else if let appleScriptsDirectory = try container.decodeIfPresent(String.self, forKey: .appleScriptsDir) {
            paths.appleScriptsDirectory = appleScriptsDirectory
        }
        if let logsBaseDirectory = try container.decodeIfPresent(String.self, forKey: .logsBaseDirectory) {
            paths.logsBaseDirectory = logsBaseDirectory
        } else if let logsBaseDirectory = try container.decodeIfPresent(String.self, forKey: .logsBaseDir) {
            paths.logsBaseDirectory = logsBaseDirectory
        }
        if let apiCacheFile = try container.decodeIfPresent(String.self, forKey: .apiCacheFile) {
            paths.apiCacheFile = apiCacheFile
        }
    }

    private mutating func applyLegacyRuntimeConfiguration(
        from container: KeyedDecodingContainer<DecodingKeys>
    ) throws {
        if let dryRun = try container.decodeIfPresent(Bool.self, forKey: .dryRun) {
            runtime.dryRun = dryRun
        }
        if let cacheTTLSeconds = try container.decodeIfPresent(Int.self, forKey: .cacheTTLSeconds) {
            runtime.cacheTTLSeconds = cacheTTLSeconds
        } else if let cacheTTLSeconds = try container.decodeIfPresent(Int.self, forKey: .cacheTtlSeconds) {
            runtime.cacheTTLSeconds = cacheTTLSeconds
        }
        if let incrementalIntervalMinutes = try container.decodeIfPresent(
            Int.self,
            forKey: .incrementalIntervalMinutes
        ) {
            runtime.incrementalIntervalMinutes = incrementalIntervalMinutes
        }
        if let maxRetries = try container.decodeIfPresent(Int.self, forKey: .maxRetries) {
            runtime.maxRetries = maxRetries
        }
        if let retryDelaySeconds = try container.decodeIfPresent(Double.self, forKey: .retryDelaySeconds) {
            runtime.retryDelaySeconds = retryDelaySeconds
        }
        if let maxGenericEntries = try container.decodeIfPresent(Int.self, forKey: .maxGenericEntries) {
            runtime.maxGenericEntries = maxGenericEntries
        }
    }

    private mutating func applyLegacyAppleScriptConfiguration(
        from container: KeyedDecodingContainer<DecodingKeys>
    ) throws {
        if let concurrency = try container.decodeIfPresent(Int.self, forKey: .appleScriptConcurrency) {
            applescript.concurrency = concurrency
        }
        if let rateLimit = try container.decodeIfPresent(AppleScriptRateLimit.self, forKey: .appleScriptRateLimit) {
            applescript.rateLimit = rateLimit
        }
        if let defaultTimeout = try container.decodeIfPresent(Int.self, forKey: .applescriptTimeoutSeconds) {
            applescript.timeouts.defaultTimeout = .seconds(defaultTimeout)
        }
        if let timeouts = try container.decodeIfPresent(AppleScriptTimeouts.self, forKey: .applescriptTimeouts) {
            applescript.timeouts = timeouts
        }
        if let retry = try container.decodeIfPresent(AppleScriptRetry.self, forKey: .applescriptRetry) {
            applescript.retry = retry
        }
        if let batchProcessing = try container.decodeIfPresent(BatchProcessingConfig.self, forKey: .batchProcessing) {
            applescript.batchProcessing = batchProcessing
        }
    }

    private mutating func applyLegacyProcessingConfiguration(
        from container: KeyedDecodingContainer<DecodingKeys>
    ) throws {
        if !container.contains(.processing), container.contains(.yearRetrieval) {
            let yearRetrievalContainer = try container.nestedContainer(
                keyedBy: YearRetrievalDecodingKeys.self,
                forKey: .yearRetrieval
            )
            if let yearRetrievalProcessing = try yearRetrievalContainer.decodeIfPresent(
                ProcessingConfig.self,
                forKey: .processing
            ) {
                processing = yearRetrievalProcessing
            }
        }
    }

    private mutating func applyLegacyDevelopmentConfiguration(
        from container: KeyedDecodingContainer<DecodingKeys>
    ) throws {
        if development.testArtists.isEmpty,
           let legacyTestArtists = try container.decodeIfPresent([String].self, forKey: .testArtists),
           !legacyTestArtists.isEmpty {
            development.testArtists = legacyTestArtists
        }
    }

    /// Load configuration from the app's container.
    public static func load() throws -> Self {
        let url = configFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Self()
        }
        let data = try Data(contentsOf: url)
        return try configurationDecoder().decode(Self.self, from: data)
    }

    /// Save configuration to the app's container.
    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: Self.configFileURL, options: .atomic)
    }

    /// Path to the JSON config file in the app's Application Support directory.
    public static var configFileURL: URL {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            preconditionFailure("Application Support directory unavailable")
        }
        let appDir = appSupport.appendingPathComponent("GenreUpdater", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("config.json")
    }

    /// Decoder for persisted and Python-era configuration keys.
    public static func configurationDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
