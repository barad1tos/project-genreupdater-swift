// AppConfiguration.swift — Application configuration model
// Ported from: src/core/core_config.py (325 LOC) + track_models.py config models (400 LOC)
//
// Key differences from Python:
// - Codable replaces Pydantic BaseModel (compiler-synthesized conformance)
// - @AppStorage used in Views for persisted preferences
// - Keychain for API keys (not config file)
// - No YAML parsing needed — config stored as JSON in app container
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
/// For users migrating from the Python CLI, `AppConfiguration.fromLegacyYAML()`
/// can import their existing config.yaml.
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

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
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
    }

    /// Load configuration from the app's container.
    public static func load() throws -> Self {
        let url = configFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Self()
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Self.self, from: data)
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
}
