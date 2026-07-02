import Core
import Foundation

// MARK: - Sync Error

public enum LibrarySyncError: Error, LocalizedError {
    case featureNotAvailable(feature: AppFeature, currentTier: Tier)
    case syncAlreadyRunning

    public var errorDescription: String? {
        switch self {
        case let .featureNotAvailable(feature, tier):
            "\(feature.rawValue) requires a higher tier than \(tier)"
        case .syncAlreadyRunning:
            "Auto-sync is already running"
        }
    }
}

// MARK: - Sync Result

/// Result of comparing the current library state against the last known state.
public struct SyncResult: Sendable {
    public let newTracks: [Track]
    public let modifiedTracks: [Track]
    /// Tracks whose album lookup identity changed without a managed metadata delta.
    public let identityChangedTracks: [Track]
    /// Tracks whose display metadata changed without managed metadata or album identity changes.
    public let refreshedTracks: [Track]
    public let removedTrackIDs: [String]

    public var changeCount: Int {
        newTracks.count
            + modifiedTracks.count
            + identityChangedTracks.count
            + refreshedTracks.count
            + removedTrackIDs.count
    }

    public var hasChanges: Bool {
        changeCount > 0
    }

    public init(
        newTracks: [Track] = [],
        modifiedTracks: [Track] = [],
        identityChangedTracks: [Track] = [],
        refreshedTracks: [Track] = [],
        removedTrackIDs: [String] = []
    ) {
        self.newTracks = newTracks
        self.modifiedTracks = modifiedTracks
        self.identityChangedTracks = identityChangedTracks
        self.refreshedTracks = refreshedTracks
        self.removedTrackIDs = removedTrackIDs
    }
}

/// Result of validating the persisted track database against Music.app.
public struct DatabaseVerificationResult: Sendable, Equatable {
    public let verifiedTrackCount: Int
    public let removedTrackIDs: [String]
    public let skippedDueToRecentVerification: Bool

    public var removedCount: Int {
        removedTrackIDs.count
    }

    public init(
        verifiedTrackCount: Int,
        removedTrackIDs: [String],
        skippedDueToRecentVerification: Bool = false
    ) {
        self.verifiedTrackCount = verifiedTrackCount
        self.removedTrackIDs = removedTrackIDs
        self.skippedDueToRecentVerification = skippedDueToRecentVerification
    }
}

/// Runtime settings for library reads and AppleScript-backed enrichment.
public struct LibrarySyncRuntimeConfiguration: Sendable, Equatable {
    public let idsBatchSize: Int
    public let fullLibraryFetchTimeout: Duration
    public let idsBatchFetchTimeout: Duration
    public let databaseVerificationBatchSize: Int
    public let databaseVerificationIntervalDays: Int
    public let forceMetadataScanIntervalDays: Int
    public let logsBaseDirectory: String
    public let lastDatabaseVerifyLog: String
    public let testArtists: [String]

    public init(
        idsBatchSize: Int = BatchProcessingConfig().idsBatchSize,
        fullLibraryFetchTimeout: Duration = AppleScriptTimeouts().fullLibraryFetch,
        idsBatchFetchTimeout: Duration = AppleScriptTimeouts().idsBatchFetch,
        databaseVerificationBatchSize: Int = DatabaseVerificationConfig().batchSize,
        databaseVerificationIntervalDays: Int = DatabaseVerificationConfig().autoVerifyDays,
        forceMetadataScanIntervalDays: Int = 7,
        logsBaseDirectory: String = PathsConfig().logsBaseDirectory,
        lastDatabaseVerifyLog: String = LoggingConfig().lastDatabaseVerifyLog,
        testArtists: [String] = []
    ) {
        self.idsBatchSize = max(1, idsBatchSize)
        self.fullLibraryFetchTimeout = fullLibraryFetchTimeout
        self.idsBatchFetchTimeout = idsBatchFetchTimeout
        self.databaseVerificationBatchSize = max(1, databaseVerificationBatchSize)
        self.databaseVerificationIntervalDays = max(0, databaseVerificationIntervalDays)
        self.forceMetadataScanIntervalDays = max(0, forceMetadataScanIntervalDays)
        self.logsBaseDirectory = logsBaseDirectory
        self.lastDatabaseVerifyLog = lastDatabaseVerifyLog
        self.testArtists = ArtistAllowList.normalized(testArtists)
    }

    public init(configuration: AppConfiguration) {
        self.init(
            idsBatchSize: configuration.applescript.batchProcessing.idsBatchSize,
            fullLibraryFetchTimeout: configuration.applescript.timeouts.fullLibraryFetch,
            idsBatchFetchTimeout: configuration.applescript.timeouts.idsBatchFetch,
            databaseVerificationBatchSize: configuration.databaseVerification.batchSize,
            databaseVerificationIntervalDays: configuration.databaseVerification.autoVerifyDays,
            logsBaseDirectory: configuration.paths.effectiveLogsBaseDirectory,
            lastDatabaseVerifyLog: configuration.logging.lastDatabaseVerifyLog,
            testArtists: configuration.development.testArtists
        )
    }
}
