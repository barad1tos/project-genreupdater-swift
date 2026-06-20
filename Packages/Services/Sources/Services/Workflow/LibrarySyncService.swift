import Core
import Foundation
import OSLog

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
    public let removedTrackIDs: [String]

    public var hasChanges: Bool {
        !newTracks.isEmpty || !modifiedTracks.isEmpty || !removedTrackIDs.isEmpty
    }

    public init(
        newTracks: [Track] = [],
        modifiedTracks: [Track] = [],
        removedTrackIDs: [String] = []
    ) {
        self.newTracks = newTracks
        self.modifiedTracks = modifiedTracks
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

// MARK: - Library Sync Service

/// Runtime settings used while reading library state through AppleScript.
public struct LibrarySyncRuntimeConfiguration: Sendable, Equatable {
    public let idsBatchSize: Int
    public let fullLibraryFetchTimeout: Duration
    public let idsBatchFetchTimeout: Duration
    public let databaseVerificationBatchSize: Int
    public let databaseVerificationIntervalDays: Int
    public let logsBaseDirectory: String
    public let lastDatabaseVerifyLog: String

    public init(
        idsBatchSize: Int = BatchProcessingConfig().idsBatchSize,
        fullLibraryFetchTimeout: Duration = AppleScriptTimeouts().fullLibraryFetch,
        idsBatchFetchTimeout: Duration = AppleScriptTimeouts().idsBatchFetch,
        databaseVerificationBatchSize: Int = DatabaseVerificationConfig().batchSize,
        databaseVerificationIntervalDays: Int = DatabaseVerificationConfig().autoVerifyDays,
        logsBaseDirectory: String = PathsConfig().logsBaseDirectory,
        lastDatabaseVerifyLog: String = LoggingConfig().lastDatabaseVerifyLog
    ) {
        self.idsBatchSize = max(1, idsBatchSize)
        self.fullLibraryFetchTimeout = fullLibraryFetchTimeout
        self.idsBatchFetchTimeout = idsBatchFetchTimeout
        self.databaseVerificationBatchSize = max(1, databaseVerificationBatchSize)
        self.databaseVerificationIntervalDays = max(0, databaseVerificationIntervalDays)
        self.logsBaseDirectory = logsBaseDirectory
        self.lastDatabaseVerifyLog = lastDatabaseVerifyLog
    }

    public init(configuration: AppConfiguration) {
        self.init(
            idsBatchSize: configuration.applescript.batchProcessing.idsBatchSize,
            fullLibraryFetchTimeout: configuration.applescript.timeouts.fullLibraryFetch,
            idsBatchFetchTimeout: configuration.applescript.timeouts.idsBatchFetch,
            databaseVerificationBatchSize: configuration.databaseVerification.batchSize,
            databaseVerificationIntervalDays: configuration.databaseVerification.autoVerifyDays,
            logsBaseDirectory: configuration.paths.effectiveLogsBaseDirectory,
            lastDatabaseVerifyLog: configuration.logging.lastDatabaseVerifyLog
        )
    }
}

/// Detects library changes and suggests updates for new/modified tracks.
///
/// Manual sync (all tiers): compare current library IDs against stored state.
/// Auto-sync (Pro only): periodic background polling with configurable interval.
public actor LibrarySyncService {
    private let scriptBridge: any AppleScriptClient
    private let trackStore: any TrackStateStore
    private let featureGate: FeatureGate
    private var runtimeConfiguration: LibrarySyncRuntimeConfiguration
    private var autoSyncTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.genreupdater", category: "LibrarySyncService")

    public init(
        scriptBridge: any AppleScriptClient,
        trackStore: any TrackStateStore,
        featureGate: FeatureGate,
        runtimeConfiguration: LibrarySyncRuntimeConfiguration = LibrarySyncRuntimeConfiguration()
    ) {
        self.scriptBridge = scriptBridge
        self.trackStore = trackStore
        self.featureGate = featureGate
        self.runtimeConfiguration = runtimeConfiguration
    }

    public func updateRuntimeConfiguration(_ runtimeConfiguration: LibrarySyncRuntimeConfiguration) {
        self.runtimeConfiguration = runtimeConfiguration
    }

    // MARK: Manual Sync

    /// Detect changes between the current Music.app library and stored state.
    public func detectChanges() async throws -> SyncResult {
        let libraryIDs = try await scriptBridge.fetchAllTrackIDs(
            timeout: runtimeConfiguration.fullLibraryFetchTimeout
        )
        let storedTracks = try await trackStore.loadAllTracks()
        let storedByID = Dictionary(uniqueKeysWithValues: storedTracks.map { ($0.id, $0) })
        let storedIDSet = Set(storedByID.keys)
        let libraryIDSet = Set(libraryIDs)

        // New tracks: in library but not in store
        let newIDs = libraryIDSet.subtracting(storedIDSet)

        // Removed tracks: in store but not in library
        let removedIDs = storedIDSet.subtracting(libraryIDSet).sorted()

        // Fetch full metadata for new tracks
        let newTracks: [Track] = if !newIDs.isEmpty {
            try await scriptBridge.fetchTracksByIDs(
                Array(newIDs),
                batchSize: runtimeConfiguration.idsBatchSize,
                timeout: runtimeConfiguration.idsBatchFetchTimeout
            )
        } else {
            []
        }

        // Modified tracks: exist in both, but need refresh to detect changes.
        // We fetch current state for tracks that exist in both sets,
        // then compare lastModified timestamps.
        let commonIDs = libraryIDSet.intersection(storedIDSet)
        var modifiedTracks: [Track] = []

        if !commonIDs.isEmpty {
            let currentTracks = try await scriptBridge.fetchTracksByIDs(
                Array(commonIDs),
                batchSize: runtimeConfiguration.idsBatchSize,
                timeout: runtimeConfiguration.idsBatchFetchTimeout
            )
            for current in currentTracks {
                guard let stored = storedByID[current.id] else { continue }
                if hasTrackChanged(current: current, stored: stored) {
                    modifiedTracks.append(current)
                }
            }
        }

        let result = SyncResult(
            newTracks: newTracks,
            modifiedTracks: modifiedTracks,
            removedTrackIDs: removedIDs
        )

        log
            .info(
                "Sync detected: \(result.newTracks.count, privacy: .public) new, \(result.modifiedTracks.count, privacy: .public) modified, \(result.removedTrackIDs.count, privacy: .public) removed"
            )
        return result
    }

    public func verifyAndCleanDatabase(force: Bool = false) async throws -> DatabaseVerificationResult {
        let storedTracks = try await trackStore.loadAllTracks()
        guard !storedTracks.isEmpty else {
            return DatabaseVerificationResult(
                verifiedTrackCount: 0,
                removedTrackIDs: []
            )
        }

        if !force, shouldSkipDatabaseVerification() {
            return DatabaseVerificationResult(
                verifiedTrackCount: storedTracks.count,
                removedTrackIDs: [],
                skippedDueToRecentVerification: true
            )
        }

        let libraryIDs = try await scriptBridge.fetchAllTrackIDs(
            timeout: runtimeConfiguration.fullLibraryFetchTimeout
        )
        let storedIDSet = Set(storedTracks.map(\.id))
        let libraryIDSet = Set(libraryIDs)

        guard !libraryIDSet.isEmpty else {
            log.warning("Database verification skipped because Music.app returned no track IDs")
            try updateDatabaseVerificationTimestamp()
            return DatabaseVerificationResult(
                verifiedTrackCount: storedTracks.count,
                removedTrackIDs: []
            )
        }

        let removedIDs = storedIDSet.subtracting(libraryIDSet).sorted()
        for chunk in removedIDs.chunked(into: runtimeConfiguration.databaseVerificationBatchSize) {
            try await trackStore.deleteTrackIDs(chunk)
        }

        try updateDatabaseVerificationTimestamp()
        log.info(
            "Database verification complete: \(storedTracks.count, privacy: .public) verified, \(removedIDs.count, privacy: .public) removed"
        )

        return DatabaseVerificationResult(
            verifiedTrackCount: storedTracks.count,
            removedTrackIDs: removedIDs
        )
    }

    /// Detect and persist Music.app library changes in the local store.
    @discardableResult
    public func synchronizeNow() async throws -> SyncResult {
        let result = try await detectChanges()
        try await applyDetectedChanges(result)
        return result
    }

    // MARK: Auto Sync

    /// Start periodic background sync (Pro only).
    public func startAutoSync(interval: Duration) async throws {
        guard await featureGate.canAccess(.autoSync) else {
            throw await LibrarySyncError.featureNotAvailable(
                feature: .autoSync,
                currentTier: featureGate.currentTier
            )
        }
        guard autoSyncTask == nil else {
            throw LibrarySyncError.syncAlreadyRunning
        }

        log.info("Starting auto-sync with interval \(interval, privacy: .public)")
        autoSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    break
                }
                guard let self else { break }
                do {
                    let result = try await self.synchronizeNow()
                    if result.hasChanges {
                        self.log
                            .info(
                                "Auto-sync applied changes: \(result.newTracks.count, privacy: .public) new, \(result.modifiedTracks.count, privacy: .public) modified, \(result.removedTrackIDs.count, privacy: .public) removed"
                            )
                    }
                } catch {
                    self.log.error("Auto-sync error: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Stop the background auto-sync loop.
    public func stopAutoSync() {
        autoSyncTask?.cancel()
        autoSyncTask = nil
        log.info("Auto-sync stopped")
    }

    /// Whether auto-sync is currently running.
    public var isAutoSyncRunning: Bool {
        guard let task = autoSyncTask else { return false }
        return !task.isCancelled
    }

    // MARK: Helpers

    private func hasTrackChanged(current: Track, stored: Track) -> Bool {
        if let currentMod = current.lastModified, let storedMod = stored.lastModified {
            if currentMod > storedMod {
                return true
            }
            if currentMod < storedMod {
                return false
            }
        }

        return TrackFingerprint.hash(current) != TrackFingerprint.hash(stored)
    }

    private func applyDetectedChanges(_ result: SyncResult) async throws {
        let refreshedTracks = result.newTracks + result.modifiedTracks
        if !refreshedTracks.isEmpty {
            try await trackStore.saveTracks(refreshedTracks)
        }

        if !result.removedTrackIDs.isEmpty {
            _ = try await trackStore.deleteTrackIDs(result.removedTrackIDs)
        }
    }

    private func shouldSkipDatabaseVerification(now: Date = Date()) -> Bool {
        guard runtimeConfiguration.databaseVerificationIntervalDays > 0 else {
            return false
        }

        let timestampURL = databaseVerificationTimestampURL()
        guard
            let timestamp = try? String(contentsOf: timestampURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let lastVerification = Self.iso8601Formatter.date(from: timestamp)
        else {
            return false
        }

        let elapsed = now.timeIntervalSince(lastVerification)
        let requiredInterval = TimeInterval(runtimeConfiguration.databaseVerificationIntervalDays) * 86400
        return elapsed < requiredInterval
    }

    private func updateDatabaseVerificationTimestamp(now: Date = Date()) throws {
        let timestampURL = databaseVerificationTimestampURL()
        try FileManager.default.createDirectory(
            at: timestampURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let timestamp = Self.iso8601Formatter.string(from: now)
        try timestamp.write(to: timestampURL, atomically: true, encoding: .utf8)
    }

    private func databaseVerificationTimestampURL() -> URL {
        let logsDirectory = Self.resolvedURL(path: runtimeConfiguration.logsBaseDirectory)
        return Self.resolvedURL(
            path: runtimeConfiguration.lastDatabaseVerifyLog,
            relativeTo: logsDirectory
        )
    }

    private static var iso8601Formatter: ISO8601DateFormatter {
        ISO8601DateFormatter()
    }

    private static func resolvedURL(path: String, relativeTo baseURL: URL? = nil) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let appSupport = defaultDirectory().path
        var expandedPath = path
            .replacingOccurrences(of: "${APP_SUPPORT}", with: appSupport)
            .replacingOccurrences(of: "${HOME}", with: home)
            .replacingOccurrences(of: "$HOME", with: home)
        if expandedPath == "~" {
            expandedPath = home
        } else if expandedPath.hasPrefix("~/") {
            expandedPath = home + String(expandedPath.dropFirst())
        }

        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath)
        }
        return (baseURL ?? FileManager.default.temporaryDirectory).appendingPathComponent(expandedPath)
    }

    private static func defaultDirectory() -> URL {
        let directories = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )
        guard let appSupport = directories.first else {
            return URL(fileURLWithPath: NSTemporaryDirectory())
        }
        return appSupport.appendingPathComponent("GenreUpdater", isDirectory: true)
    }
}
