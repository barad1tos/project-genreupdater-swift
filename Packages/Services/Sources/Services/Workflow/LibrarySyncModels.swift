import Core
import Foundation

// MARK: - Sync Error

// MARK: - Sync Result

/// Result of comparing the current library state against the last known state.
public struct SyncResult: Sendable, Equatable {
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

/// Retry policy for optimistic mirror commits.
public struct MirrorRetryPolicy: Sendable, Equatable {
    public let retryLimit: Int
    public let delay: Duration

    public init(retryLimit: Int, delay: Duration) {
        self.retryLimit = max(0, retryLimit)
        self.delay = max(.zero, delay)
    }

    public init(configuration: LibrarySyncConfig) {
        self.init(
            retryLimit: configuration.conflictRetries,
            delay: .milliseconds(Int64(configuration.conflictDelaySeconds * 1000))
        )
    }
}

/// Runtime policy for library sync scope, refresh cadence, and verification logs.
public struct LibrarySyncRuntimeConfiguration: Sendable, Equatable {
    public let databaseVerificationIntervalDays: Int
    public let forceMetadataScanIntervalDays: Int
    public let logsBaseDirectory: String
    public let lastDatabaseVerifyLog: String
    public let testArtists: [String]
    public let mirrorRetryPolicy: MirrorRetryPolicy
    /// A preview's album target: every load path narrows through the
    /// read request's admission predicate when this is set.
    public let albumTargetIdentity: AlbumIdentity?

    public init(
        databaseVerificationIntervalDays: Int = DatabaseVerificationConfig().autoVerifyDays,
        forceMetadataScanIntervalDays: Int = 7,
        logsBaseDirectory: String = PathsConfig().logsBaseDirectory,
        lastDatabaseVerifyLog: String = LoggingConfig().lastDatabaseVerifyLog,
        testArtists: [String] = [],
        mirrorRetryPolicy: MirrorRetryPolicy = MirrorRetryPolicy(configuration: LibrarySyncConfig()),
        albumTargetIdentity: AlbumIdentity? = nil
    ) {
        self.databaseVerificationIntervalDays = max(0, databaseVerificationIntervalDays)
        self.forceMetadataScanIntervalDays = max(0, forceMetadataScanIntervalDays)
        self.logsBaseDirectory = logsBaseDirectory
        self.lastDatabaseVerifyLog = lastDatabaseVerifyLog
        self.testArtists = ArtistAllowList.normalized(testArtists)
        self.mirrorRetryPolicy = mirrorRetryPolicy
        self.albumTargetIdentity = albumTargetIdentity
    }

    public init(configuration: AppConfiguration, albumTargetIdentity: AlbumIdentity? = nil) {
        self.init(
            databaseVerificationIntervalDays: configuration.databaseVerification.autoVerifyDays,
            logsBaseDirectory: configuration.paths.effectiveLogsBaseDirectory,
            lastDatabaseVerifyLog: configuration.logging.lastDatabaseVerifyLog,
            testArtists: configuration.development.testArtists,
            mirrorRetryPolicy: MirrorRetryPolicy(configuration: configuration.librarySync),
            albumTargetIdentity: albumTargetIdentity
        )
    }
}
