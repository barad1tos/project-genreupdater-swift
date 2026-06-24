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
    /// Tracks whose album lookup identity changed without a managed metadata delta.
    public let identityChangedTracks: [Track]
    public let removedTrackIDs: [String]

    public var hasChanges: Bool {
        !newTracks.isEmpty || !modifiedTracks.isEmpty || !identityChangedTracks.isEmpty || !removedTrackIDs.isEmpty
    }

    public init(
        newTracks: [Track] = [],
        modifiedTracks: [Track] = [],
        identityChangedTracks: [Track] = [],
        removedTrackIDs: [String] = []
    ) {
        self.newTracks = newTracks
        self.modifiedTracks = modifiedTracks
        self.identityChangedTracks = identityChangedTracks
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
    public let forceMetadataScanIntervalDays: Int
    public let logsBaseDirectory: String
    public let lastDatabaseVerifyLog: String

    public init(
        idsBatchSize: Int = BatchProcessingConfig().idsBatchSize,
        fullLibraryFetchTimeout: Duration = AppleScriptTimeouts().fullLibraryFetch,
        idsBatchFetchTimeout: Duration = AppleScriptTimeouts().idsBatchFetch,
        databaseVerificationBatchSize: Int = DatabaseVerificationConfig().batchSize,
        databaseVerificationIntervalDays: Int = DatabaseVerificationConfig().autoVerifyDays,
        forceMetadataScanIntervalDays: Int = 7,
        logsBaseDirectory: String = PathsConfig().logsBaseDirectory,
        lastDatabaseVerifyLog: String = LoggingConfig().lastDatabaseVerifyLog
    ) {
        self.idsBatchSize = max(1, idsBatchSize)
        self.fullLibraryFetchTimeout = fullLibraryFetchTimeout
        self.idsBatchFetchTimeout = idsBatchFetchTimeout
        self.databaseVerificationBatchSize = max(1, databaseVerificationBatchSize)
        self.databaseVerificationIntervalDays = max(0, databaseVerificationIntervalDays)
        self.forceMetadataScanIntervalDays = max(0, forceMetadataScanIntervalDays)
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
    private let cache: (any CacheService)?
    private var pendingVerificationService: (any PendingVerificationService)?
    private var librarySnapshotService: (any LibrarySnapshotService)?
    private var runtimeConfiguration: LibrarySyncRuntimeConfiguration
    private let currentDate: @Sendable () -> Date
    private var autoSyncTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.genreupdater", category: "LibrarySyncService")

    public init(
        scriptBridge: any AppleScriptClient,
        trackStore: any TrackStateStore,
        featureGate: FeatureGate,
        cache: (any CacheService)? = nil,
        pendingVerificationService: (any PendingVerificationService)? = nil,
        librarySnapshotService: (any LibrarySnapshotService)? = nil,
        runtimeConfiguration: LibrarySyncRuntimeConfiguration = LibrarySyncRuntimeConfiguration(),
        currentDate: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.scriptBridge = scriptBridge
        self.trackStore = trackStore
        self.featureGate = featureGate
        self.cache = cache
        self.pendingVerificationService = pendingVerificationService
        self.librarySnapshotService = librarySnapshotService
        self.runtimeConfiguration = runtimeConfiguration
        self.currentDate = currentDate
    }

    public func updateRuntimeConfiguration(
        _ runtimeConfiguration: LibrarySyncRuntimeConfiguration,
        librarySnapshotService: (any LibrarySnapshotService)? = nil,
        pendingVerificationService: (any PendingVerificationService)? = nil
    ) {
        self.runtimeConfiguration = runtimeConfiguration
        if let librarySnapshotService {
            self.librarySnapshotService = librarySnapshotService
        }
        if let pendingVerificationService {
            self.pendingVerificationService = pendingVerificationService
        }
    }

    // MARK: Manual Sync

    /// Detect changes between the current Music.app library and stored state.
    public func detectChanges(forceMetadataRefresh: Bool = false) async throws -> SyncResult {
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

        let commonIDs = libraryIDSet.intersection(storedIDSet)
        var modifiedTracks: [Track] = []
        var identityChangedTracks: [Track] = []

        if !commonIDs.isEmpty, try await shouldRefreshCommonTrackMetadata(force: forceMetadataRefresh) {
            let currentTracks = try await scriptBridge.fetchTracksByIDs(
                Array(commonIDs),
                batchSize: runtimeConfiguration.idsBatchSize,
                timeout: runtimeConfiguration.idsBatchFetchTimeout
            )
            for current in currentTracks {
                guard let stored = storedByID[current.id] else { continue }
                if hasTrackChanged(current: current, stored: stored) {
                    modifiedTracks.append(current)
                } else if hasIdentityChanged(current: current, stored: stored) {
                    identityChangedTracks.append(current)
                }
            }
            try await updateForceScanDate()
        }

        let result = SyncResult(
            newTracks: newTracks,
            modifiedTracks: modifiedTracks,
            identityChangedTracks: identityChangedTracks,
            removedTrackIDs: removedIDs
        )

        log
            .info(
                """
                Sync detected: \(result.newTracks.count, privacy: .public) new, \
                \(result.modifiedTracks.count, privacy: .public) modified, \
                \(result.identityChangedTracks.count, privacy: .public) identity changed, \
                \(result.removedTrackIDs.count, privacy: .public) removed
                """
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
        let removedIDSet = Set(removedIDs)
        let removedTracks = storedTracks.filter { removedIDSet.contains($0.id) }
        await invalidateCachesForLibraryChanges(
            hasLibraryChanges: !removedTracks.isEmpty,
            targets: cacheInvalidationTargets(removedTracks: removedTracks)
        )

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
    public func synchronizeNow(forceMetadataRefresh: Bool = false) async throws -> SyncResult {
        let result = try await detectChanges(forceMetadataRefresh: forceMetadataRefresh)
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
                                """
                                Auto-sync applied changes: \
                                \(result.newTracks.count, privacy: .public) new, \
                                \(result.modifiedTracks.count, privacy: .public) modified, \
                                \(result.identityChangedTracks.count, privacy: .public) identity changed, \
                                \(result.removedTrackIDs.count, privacy: .public) removed
                                """
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
        TrackFingerprint.hasProcessingMetadataChanged(current: current, stored: stored)
    }

    private func shouldRefreshCommonTrackMetadata(force: Bool) async throws -> Bool {
        if force { return true }
        guard runtimeConfiguration.forceMetadataScanIntervalDays > 0,
              let metadata = await librarySnapshotService?.getSnapshotMetadata()
        else { return false }
        guard let lastForceScanDate = metadata.lastForceScanDate else {
            try await updateForceScanDate()
            return false
        }

        let interval = TimeInterval(runtimeConfiguration.forceMetadataScanIntervalDays) * 86400
        return currentDate().timeIntervalSince(lastForceScanDate) >= interval
    }

    private func updateForceScanDate() async throws {
        guard var metadata = await librarySnapshotService?.getSnapshotMetadata() else { return }
        metadata.lastForceScanDate = currentDate()
        try await librarySnapshotService?.updateSnapshotMetadata(metadata)
    }

    private func applyDetectedChanges(_ result: SyncResult) async throws {
        let storedTracks = try await trackStore.loadAllTracks()
        let storedByID = Dictionary(uniqueKeysWithValues: storedTracks.map { ($0.id, $0) })
        let refreshedTracks = result.newTracks + result.modifiedTracks + result.identityChangedTracks
        if !refreshedTracks.isEmpty {
            try await trackStore.saveTracks(refreshedTracks)
        }

        if !result.removedTrackIDs.isEmpty {
            _ = try await trackStore.deleteTrackIDs(result.removedTrackIDs)
        }

        await invalidateCachesForLibraryChanges(
            hasLibraryChanges: result.hasChanges,
            targets: cacheInvalidationTargets(
                newTracks: result.newTracks,
                modifiedTracks: result.modifiedTracks,
                identityChangedTracks: result.identityChangedTracks,
                removedTrackIDs: result.removedTrackIDs,
                storedByID: storedByID
            )
        )
        try await removeResolvedPrereleasePendingEntries(
            refreshedTracks: result.modifiedTracks + result.identityChangedTracks,
            previousTracksByID: storedByID
        )
    }

    private func invalidateCachesForLibraryChanges(
        hasLibraryChanges: Bool,
        targets: [(artist: String, album: String)]
    ) async {
        guard hasLibraryChanges else { return }
        for target in targets {
            await cache?.invalidateAlbum(artist: target.artist, album: target.album)
            await cache?.invalidateCachedAPIResults(artist: target.artist, album: target.album)
        }
        await librarySnapshotService?.clearSnapshot()
    }

    private func cacheInvalidationTargets(
        newTracks: [Track] = [],
        modifiedTracks: [Track] = [],
        identityChangedTracks: [Track] = [],
        removedTrackIDs: [String] = [],
        storedByID: [String: Track]
    ) -> [(artist: String, album: String)] {
        var candidates: [(artist: String, album: String)] = []

        candidates.append(contentsOf: newTracks.flatMap { cacheInvalidationTargets(for: $0) })

        for current in modifiedTracks {
            candidates.append(contentsOf: cacheInvalidationTargets(for: current))
            if let stored = storedByID[current.id],
               hasIdentityChanged(current: current, stored: stored) {
                candidates.append(contentsOf: cacheInvalidationTargets(for: stored))
            }
        }

        for current in identityChangedTracks {
            guard let stored = storedByID[current.id] else { continue }
            candidates.append(contentsOf: cacheInvalidationTargets(for: stored))
            candidates.append(contentsOf: cacheInvalidationTargets(for: current))
        }

        let removedIDSet = Set(removedTrackIDs)
        let removedTracks = storedByID.values.filter { removedIDSet.contains($0.id) }
        candidates.append(contentsOf: cacheInvalidationTargets(removedTracks: removedTracks))

        return normalizedCacheInvalidationTargets(candidates)
    }

    private func cacheInvalidationTargets(removedTracks: [Track]) -> [(artist: String, album: String)] {
        normalizedCacheInvalidationTargets(
            removedTracks.flatMap { cacheInvalidationTargets(for: $0) }
        )
    }

    private func hasIdentityChanged(current: Track, stored: Track) -> Bool {
        Set(AlbumIdentity.lookupKeys(for: current)) != Set(AlbumIdentity.lookupKeys(for: stored))
    }

    private func cacheInvalidationTargets(for track: Track) -> [(artist: String, album: String)] {
        AlbumIdentity.lookupCandidates(for: track).map { identity in
            (artist: identity.artist, album: identity.album)
        }
    }

    private func removeResolvedPrereleasePendingEntries(
        refreshedTracks: [Track],
        previousTracksByID: [String: Track]
    ) async throws {
        guard let pendingVerificationService else { return }

        let transitionedAlbums = refreshedTracks.flatMap { current -> [(artist: String, album: String)] in
            guard let previous = previousTracksByID[current.id],
                  previous.kind == .prerelease,
                  UpdateCoordinator.isTrackAvailableForProcessing(current)
            else {
                return []
            }
            return (AlbumIdentity.lookupCandidates(for: current) + AlbumIdentity.lookupCandidates(for: previous))
                .map { (artist: $0.artist, album: $0.album) }
        }
        let targets = normalizedCacheInvalidationTargets(transitionedAlbums)
        guard !targets.isEmpty else { return }

        let currentTracks = try await trackStore.loadAllTracks()
        for target in targets {
            guard !hasPrereleaseTrack(in: currentTracks, artist: target.artist, album: target.album) else {
                continue
            }
            guard let entry = await pendingVerificationService.getEntry(artist: target.artist, album: target.album),
                  Self.isPrereleasePendingReason(entry.reason)
            else {
                continue
            }
            await pendingVerificationService.removeFromPending(artist: target.artist, album: target.album)
        }
    }

    private static func isPrereleasePendingReason(_ reason: String) -> Bool {
        let normalizedReason = reason
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
        return normalizedReason == "prerelease" || normalizedReason == "pre_release"
    }

    private func hasPrereleaseTrack(in tracks: [Track], artist: String, album: String) -> Bool {
        let targetKeys = Set(AlbumIdentity.lookupKeys(artist: artist, album: album))
        return tracks.contains { track in
            guard track.kind == .prerelease else { return false }
            let trackKeys = Set(AlbumIdentity.lookupKeys(for: track))
            return !targetKeys.isDisjoint(with: trackKeys)
        }
    }

    private func normalizedCacheInvalidationTargets(
        _ candidates: [(artist: String, album: String)]
    ) -> [(artist: String, album: String)] {
        var seenKeys: Set<String> = []
        return candidates.compactMap { candidate in
            let artist = candidate.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            let album = candidate.album.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !artist.isEmpty, !album.isEmpty else { return nil }

            let key = "\(normalizeForMatching(artist))\u{1F}\(normalizeForMatching(album))"
            guard seenKeys.insert(key).inserted else { return nil }
            return (artist: artist, album: album)
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
