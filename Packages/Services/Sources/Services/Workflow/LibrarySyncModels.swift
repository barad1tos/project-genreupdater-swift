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
    public let scope: ProcessingScopeSnapshot?

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
        removedTrackIDs: [String] = [],
        scope: ProcessingScopeSnapshot? = nil
    ) {
        self.newTracks = newTracks
        self.modifiedTracks = modifiedTracks
        self.identityChangedTracks = identityChangedTracks
        self.refreshedTracks = refreshedTracks
        self.removedTrackIDs = removedTrackIDs
        self.scope = scope
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
    public static let defaults: Self = {
        let configuration = LibrarySyncConfig()
        return Self(
            retryLimit: configuration.conflictRetries,
            delay: .seconds(configuration.conflictDelaySeconds)
        )
    }()

    public let retryLimit: Int
    public let delay: Duration

    public init(retryLimit: Int, delay: Duration) {
        self.retryLimit = max(0, retryLimit)
        self.delay = max(.zero, delay)
    }

    public init(configuration: LibrarySyncConfig) throws {
        let delaySeconds = configuration.conflictDelaySeconds
        let roundedMilliseconds = (delaySeconds * 1000).rounded()
        guard delaySeconds.isFinite,
              delaySeconds >= 0,
              roundedMilliseconds.isFinite,
              let delayMilliseconds = Int64(exactly: roundedMilliseconds)
        else {
            throw MirrorRetryPolicyError.invalidDelay(seconds: delaySeconds)
        }
        self.init(
            retryLimit: configuration.conflictRetries,
            delay: .milliseconds(delayMilliseconds)
        )
    }
}

enum MirrorRetryPolicyError: LocalizedError, Sendable {
    case invalidDelay(seconds: Double)

    var errorDescription: String? {
        switch self {
        case let .invalidDelay(seconds):
            "Library sync conflict delay cannot be represented safely: \(seconds) seconds."
        }
    }
}

struct SyncAttemptInput: Sendable {
    let configuration: LibrarySyncRuntimeConfiguration
    let capturedScope: ProcessingScopeSnapshot?
    let startedAt: Date
    let isForced: Bool
}

struct CertificateInput {
    let baseRevision: MirrorRevision
    let previousReadiness: MirrorReadiness
    let certifiedIDs: Set<MusicDatabaseTrackID>
    let hasTrackMutations: Bool
    let configuration: LibrarySyncRuntimeConfiguration
}

struct SyncRecordParts {
    let evidence: MirrorSyncEvidence
    let coverage: MirrorSyncCoverage
}

/// Runtime policy for library sync scope, refresh cadence, and verification logs.
public struct LibrarySyncRuntimeConfiguration: Sendable, Equatable {
    public let databaseVerificationIntervalDays: Int
    public let forceMetadataScanIntervalDays: Int
    public let logsBaseDirectory: String
    public let lastDatabaseVerifyLog: String
    public let testArtists: [String]
    public let mirrorRetryPolicy: MirrorRetryPolicy
    public let syncRecordLimit: Int
    /// Scope already captured by the run orchestrator. Direct sync callers leave this nil and capture at attempt start.
    public let capturedScope: ProcessingScopeSnapshot?
    /// A preview's album target: every load path narrows through the
    /// read request's admission predicate when this is set.
    public let albumTargetIdentity: AlbumIdentity?

    public init(
        databaseVerificationIntervalDays: Int = DatabaseVerificationConfig().autoVerifyDays,
        forceMetadataScanIntervalDays: Int = 7,
        logsBaseDirectory: String = PathsConfig().logsBaseDirectory,
        lastDatabaseVerifyLog: String = LoggingConfig().lastDatabaseVerifyLog,
        testArtists: [String] = [],
        mirrorRetryPolicy: MirrorRetryPolicy = .defaults,
        syncRecordLimit: Int = LibrarySyncConfig().syncRecordLimit,
        capturedScope: ProcessingScopeSnapshot? = nil,
        albumTargetIdentity: AlbumIdentity? = nil
    ) {
        self.databaseVerificationIntervalDays = max(0, databaseVerificationIntervalDays)
        self.forceMetadataScanIntervalDays = max(0, forceMetadataScanIntervalDays)
        self.logsBaseDirectory = logsBaseDirectory
        self.lastDatabaseVerifyLog = lastDatabaseVerifyLog
        self.testArtists = ArtistAllowList.normalized(testArtists)
        self.mirrorRetryPolicy = mirrorRetryPolicy
        self.syncRecordLimit = max(1, syncRecordLimit)
        self.capturedScope = capturedScope
        self.albumTargetIdentity = albumTargetIdentity
    }

    public init(
        configuration: AppConfiguration,
        capturedScope: ProcessingScopeSnapshot? = nil,
        albumTargetIdentity: AlbumIdentity? = nil
    ) throws {
        try self.init(
            databaseVerificationIntervalDays: configuration.databaseVerification.autoVerifyDays,
            logsBaseDirectory: configuration.paths.effectiveLogsBaseDirectory,
            lastDatabaseVerifyLog: configuration.logging.lastDatabaseVerifyLog,
            testArtists: configuration.development.testArtists,
            mirrorRetryPolicy: MirrorRetryPolicy(configuration: configuration.librarySync),
            syncRecordLimit: configuration.librarySync.syncRecordLimit,
            capturedScope: capturedScope,
            albumTargetIdentity: albumTargetIdentity
        )
    }

    /// The configured scope and freshness policy required before processing mirror rows.
    public var processingRequirement: MirrorRequirement {
        let maximumAge = forceMetadataScanIntervalDays > 0
            ? TimeInterval(forceMetadataScanIntervalDays) * 86400
            : nil
        return MirrorRequirement(
            testArtists: testArtists,
            fieldSet: .processingV1,
            maximumMetadataAge: maximumAge
        )
    }
}
