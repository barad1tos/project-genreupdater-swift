import Core
import Foundation
import OSLog

/// Detects library changes and suggests updates for new/modified tracks.
///
/// Manual sync (all tiers): compare current library IDs against stored state.
/// Auto-sync (Pro only): periodic background polling with configurable interval.
public actor LibrarySyncService {
    let scriptBridge: any AppleScriptClient
    let trackStore: any TrackStateStore
    private let featureGate: FeatureGate
    private let cache: (any CacheService)?
    private let readProvider: (any LibraryReadProvider)?
    private var pendingVerificationService: (any PendingVerificationService)?
    private var librarySnapshotService: (any LibrarySnapshotService)?
    private(set) var runtimeConfiguration: LibrarySyncRuntimeConfiguration
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
        currentDate: @escaping @Sendable () -> Date = { Date() },
        readProvider: (any LibraryReadProvider)? = nil
    ) {
        self.scriptBridge = scriptBridge
        self.trackStore = trackStore
        self.featureGate = featureGate
        self.cache = cache
        self.readProvider = readProvider
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
        // MusicKit Song does not expose Music.app album artist. Scoped test runs use
        // AppleScript so testArtists keep the same effectiveArtist semantics as writes.
        if let readProvider, runtimeConfiguration.testArtists.isEmpty {
            return try await detectChangesWithReadProvider(
                readProvider,
                forceMetadataRefresh: forceMetadataRefresh
            )
        }

        return try await detectChangesWithAppleScript(forceMetadataRefresh: forceMetadataRefresh)
    }

    private func detectChangesWithAppleScript(forceMetadataRefresh: Bool) async throws -> SyncResult {
        let librarySnapshot = try await fetchAppleScriptLibrarySnapshotForConfiguredScope()
        let storedTracks = try await loadStoredTracksInConfiguredScope()
        let storedByID = Dictionary(storedTracks.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let storedIDSet = Set(storedByID.keys)
        let libraryIDSet = Set(librarySnapshot.trackIDs)

        // New tracks: in library but not in store
        let newIDs = libraryIDSet.subtracting(storedIDSet)

        // Removed tracks: in store but not in library
        let removedIDs = storedIDSet.subtracting(libraryIDSet).sorted()

        // Fetch full metadata for new tracks
        let newTracks = try await fetchAppleScriptTracks(
            trackIDs: newIDs,
            scopedTracksByID: librarySnapshot.tracksByID
        )

        let commonIDs = libraryIDSet.intersection(storedIDSet)
        var modifiedTracks: [Track] = []
        var identityChangedTracks: [Track] = []
        var refreshedTracks: [Track] = []

        if !commonIDs.isEmpty, try await shouldRefreshCommonTrackMetadata(force: forceMetadataRefresh) {
            let currentTracks = try await fetchAppleScriptTracks(
                trackIDs: commonIDs,
                scopedTracksByID: librarySnapshot.tracksByID
            )
            for current in currentTracks {
                guard let stored = storedByID[current.id] else { continue }
                if hasTrackChanged(current: current, stored: stored) {
                    modifiedTracks.append(current)
                } else if hasIdentityChanged(current: current, stored: stored) {
                    identityChangedTracks.append(current)
                } else if hasDisplayMetadataChanged(current: current, stored: stored) {
                    refreshedTracks.append(current)
                }
            }
            try await updateForceScanDate()
        }

        let result = SyncResult(
            newTracks: newTracks,
            modifiedTracks: modifiedTracks,
            identityChangedTracks: identityChangedTracks,
            refreshedTracks: refreshedTracks,
            removedTrackIDs: removedIDs
        )

        log
            .info(
                """
                Sync detected: \(result.newTracks.count, privacy: .public) new, \
                \(result.modifiedTracks.count, privacy: .public) modified, \
                \(result.identityChangedTracks.count, privacy: .public) identity changed, \
                \(result.refreshedTracks.count, privacy: .public) refreshed, \
                \(result.removedTrackIDs.count, privacy: .public) removed
                """
            )
        return result
    }

    private func detectChangesWithReadProvider(
        _ readProvider: any LibraryReadProvider,
        forceMetadataRefresh: Bool
    ) async throws -> SyncResult {
        let snapshot = try await readProvider.loadLibrarySnapshot(request: libraryReadRequest)
        let currentTracks = snapshot.tracks
        let storedTracks = try await loadStoredTracksInConfiguredScope()
        let storedByID = Dictionary(storedTracks.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let currentByID = Dictionary(currentTracks.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let storedIDSet = Set(storedByID.keys)
        let currentIDSet = Set(currentByID.keys)

        if currentIDSet.isEmpty, !storedIDSet.isEmpty {
            log
                .warning(
                    "MusicKit snapshot is empty while stored tracks exist; removals require AppleScript confirmation"
                )
        }

        if try await shouldFallbackToAppleScriptSync(storedTracks: storedTracks, currentIDSet: currentIDSet) {
            log.warning("Falling back to AppleScript sync because stored tracks are still AppleScript-keyed")
            return try await detectChangesWithAppleScript(forceMetadataRefresh: forceMetadataRefresh)
        }

        let newTrackCandidates = currentIDSet
            .subtracting(storedIDSet)
            .sorted()
            .compactMap { currentByID[$0] }
        let removalCandidateIDs = storedIDSet.subtracting(currentIDSet)
        let mutationMetadata = try await readProviderMutationMetadata(
            for: newTrackCandidates + (
                currentIDSet.isEmpty ? [] : mutationMetadataRemovalCandidates(
                    removalCandidateIDs: removalCandidateIDs,
                    storedByID: storedByID
                )
            )
        )
        let newTracks = newTrackCandidates.map { current in
            mutationMetadata.tracksByMusicKitID[current.id] ?? current
        }
        let removalStoredByID = readProviderRemovalStoredTracks(
            storedByID: storedByID,
            mutationMetadataByID: mutationMetadata.tracksByMusicKitID
        )
        let removedIDs = try await readProviderRemovedTrackIDs(
            candidates: removalCandidateIDs,
            storedByID: removalStoredByID,
            confirmedAbsentUnmappedIDs: mutationMetadata.absentMusicKitIDs
        )
        let metadataDeltas = try await readProviderMetadataDeltas(
            currentByID: currentByID,
            storedByID: storedByID,
            commonIDs: currentIDSet.intersection(storedIDSet),
            forceMetadataRefresh: forceMetadataRefresh
        )

        let result = SyncResult(
            newTracks: newTracks,
            modifiedTracks: metadataDeltas.modifiedTracks,
            identityChangedTracks: metadataDeltas.identityChangedTracks,
            refreshedTracks: metadataDeltas.refreshedTracks,
            removedTrackIDs: removedIDs
        )

        logReadProviderSyncResult(result)
        return result
    }

    private func readProviderMetadataDeltas(
        currentByID: [String: Track],
        storedByID: [String: Track],
        commonIDs: Set<String>,
        forceMetadataRefresh: Bool
    ) async throws -> (
        modifiedTracks: [Track],
        identityChangedTracks: [Track],
        refreshedTracks: [Track]
    ) {
        guard !commonIDs.isEmpty else {
            return ([], [], [])
        }
        guard try await shouldRefreshCommonTrackMetadata(force: forceMetadataRefresh) else {
            return ([], [], [])
        }

        var modifiedTracks: [Track] = []
        var identityChangedTracks: [Track] = []
        var refreshedTracks: [Track] = []
        let appleScriptMetadataByPrimaryID = try await readProviderAppleScriptMetadataByPrimaryID(
            storedByID: storedByID,
            commonIDs: commonIDs
        )
        for trackID in commonIDs.sorted() {
            guard let current = currentByID[trackID],
                  let stored = storedByID[trackID]
            else { continue }

            let persistedCurrent = readProviderPersistenceTrack(
                current: current,
                stored: stored,
                appleScriptMetadata: appleScriptMetadataByPrimaryID[trackID],
                isAppleScriptMetadataAuthoritative: true
            )
            if hasTrackChanged(current: persistedCurrent, stored: stored) {
                modifiedTracks.append(persistedCurrent)
            } else if hasIdentityChanged(current: persistedCurrent, stored: stored) {
                identityChangedTracks.append(persistedCurrent)
            } else if hasDisplayMetadataChanged(current: persistedCurrent, stored: stored) {
                refreshedTracks.append(persistedCurrent)
            }
        }
        try await updateForceScanDate()
        return (modifiedTracks, identityChangedTracks, refreshedTracks)
    }

    private func mutationMetadataRemovalCandidates(
        removalCandidateIDs: Set<String>,
        storedByID: [String: Track]
    ) -> [Track] {
        removalCandidateIDs
            .sorted()
            .compactMap { storedByID[$0] }
            .filter { $0.appleScriptID == nil }
    }

    private func readProviderMutationMetadata(
        for tracks: [Track]
    ) async throws -> (tracksByMusicKitID: [String: Track], absentMusicKitIDs: Set<String>) {
        let tracksNeedingMetadata = tracks.filter { $0.appleScriptID == nil }
        guard !tracksNeedingMetadata.isEmpty else {
            return ([:], [])
        }

        let appleScriptTrackIDs = try await scriptBridge.fetchAllTrackIDs(
            timeout: runtimeConfiguration.fullLibraryFetchTimeout
        )
        guard !appleScriptTrackIDs.isEmpty else {
            log.warning("Skipped MusicKit mutation metadata backfill because AppleScript returned an empty library")
            return ([:], [])
        }

        let appleScriptTracks = try await scriptBridge.fetchTracksByIDs(
            appleScriptTrackIDs,
            batchSize: runtimeConfiguration.idsBatchSize,
            timeout: runtimeConfiguration.idsBatchFetchTimeout
        )
        let mapper = TrackIDMapper()
        await mapper.refreshMapping(
            musicKitTracks: tracksNeedingMetadata,
            appleScriptTracks: appleScriptTracks
        )

        var tracksByMusicKitID: [String: Track] = [:]
        for track in tracksNeedingMetadata {
            if let enrichedTrack = await mapper.trackWithAppleScriptMetadata(for: track) {
                tracksByMusicKitID[track.id] = enrichedTrack
            }
        }
        let appleScriptPresenceKeys = Set(appleScriptTracks.flatMap(readProviderPresenceKeys))
        let absentMusicKitIDs = Set(tracksNeedingMetadata.compactMap { track -> String? in
            guard tracksByMusicKitID[track.id] == nil else { return nil }
            let trackPresenceKeys = Set(readProviderPresenceKeys(for: track))
            return trackPresenceKeys.isDisjoint(with: appleScriptPresenceKeys) ? track.id : nil
        })
        return (tracksByMusicKitID, absentMusicKitIDs)
    }

    private func readProviderRemovalStoredTracks(
        storedByID: [String: Track],
        mutationMetadataByID: [String: Track]
    ) -> [String: Track] {
        var resolvedTracks = storedByID
        for (trackID, metadataTrack) in mutationMetadataByID {
            guard let stored = storedByID[trackID] else { continue }
            resolvedTracks[trackID] = readProviderPersistenceTrack(
                current: metadataTrack,
                stored: stored,
                appleScriptMetadata: metadataTrack
            )
        }
        return resolvedTracks
    }

    private func readProviderAppleScriptMetadataByPrimaryID(
        storedByID: [String: Track],
        commonIDs: Set<String>
    ) async throws -> [String: Track] {
        let candidates = commonIDs.sorted().compactMap { primaryID -> (primaryID: String, appleScriptID: String)? in
            guard let stored = storedByID[primaryID],
                  let appleScriptID = stored.appleScriptID
            else { return nil }
            return (primaryID: primaryID, appleScriptID: appleScriptID)
        }
        guard !candidates.isEmpty else { return [:] }

        let fetchedTracks = try await scriptBridge.fetchTracksByIDs(
            candidates.map(\.appleScriptID),
            batchSize: runtimeConfiguration.idsBatchSize,
            timeout: runtimeConfiguration.idsBatchFetchTimeout
        )
        let fetchedByAppleScriptID = Dictionary(
            fetchedTracks.map { ($0.appleScriptID ?? $0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        return Dictionary(uniqueKeysWithValues: candidates.compactMap { candidate in
            guard let fetched = fetchedByAppleScriptID[candidate.appleScriptID] else { return nil }
            return (candidate.primaryID, fetched)
        })
    }

    private func readProviderRemovedTrackIDs(
        candidates: Set<String>,
        storedByID: [String: Track],
        confirmedAbsentUnmappedIDs: Set<String> = []
    ) async throws -> [String] {
        let removalCandidates = candidates.sorted().compactMap { primaryID -> (
            primaryID: String,
            appleScriptID: String
        )? in
            guard let appleScriptID = storedByID[primaryID]?.appleScriptID else { return nil }
            return (primaryID: primaryID, appleScriptID: appleScriptID)
        }
        let unmappedCandidateIDs = candidates
            .filter { storedByID[$0]?.appleScriptID == nil }
            .sorted()
        let confirmedUnmappedIDs = unmappedCandidateIDs.filter { confirmedAbsentUnmappedIDs.contains($0) }
        let preservedUnmappedIDs = unmappedCandidateIDs.filter { !confirmedAbsentUnmappedIDs.contains($0) }
        if !confirmedUnmappedIDs.isEmpty {
            log
                .info(
                    """
                    Removing \(confirmedUnmappedIDs.count, privacy: .public) MusicKit removal candidates without \
                    AppleScript IDs after confirming their identity keys are absent
                    """
                )
        }
        if !preservedUnmappedIDs.isEmpty {
            log
                .warning(
                    """
                    Preserved \(preservedUnmappedIDs.count, privacy: .public) removal candidates without \
                    AppleScript IDs because AppleScript still has a possible identity match
                    """
                )
        }
        guard !removalCandidates.isEmpty else {
            return confirmedUnmappedIDs
        }

        let fetchedTracks = try await scriptBridge.fetchTracksByIDs(
            removalCandidates.map(\.appleScriptID),
            batchSize: runtimeConfiguration.idsBatchSize,
            timeout: runtimeConfiguration.idsBatchFetchTimeout
        )

        let fetchedAppleScriptIDs = Set(fetchedTracks.map { $0.appleScriptID ?? $0.id })
        let unresolvedCandidates = removalCandidates.filter {
            !fetchedAppleScriptIDs.contains($0.appleScriptID)
        }
        guard !unresolvedCandidates.isEmpty else {
            return confirmedUnmappedIDs
        }

        let libraryIDs = try await fetchAppleScriptLibraryIDsForConfiguredScope()
        guard !libraryIDs.isEmpty else {
            log.warning("Skipped MusicKit removal candidates because AppleScript returned an empty library")
            return confirmedUnmappedIDs
        }
        let existingAppleScriptIDs = Set(libraryIDs)

        let removedMappedIDs = unresolvedCandidates
            .filter { !existingAppleScriptIDs.contains($0.appleScriptID) }
            .map(\.primaryID)
        return Array(Set(removedMappedIDs + confirmedUnmappedIDs)).sorted()
    }

    private func shouldFallbackToAppleScriptSync(
        storedTracks: [Track],
        currentIDSet: Set<String>
    ) async throws -> Bool {
        guard !storedTracks.isEmpty else { return false }
        guard !currentIDSet.isEmpty else { return false }
        let storedIDSet = Set(storedTracks.map(\.id))
        guard storedIDSet.isDisjoint(with: currentIDSet) else { return false }
        if storedTracks.contains(where: { $0.appleScriptID == $0.id }) {
            return true
        }

        guard storedTracks.contains(where: { $0.appleScriptID == nil }) else { return false }
        let libraryIDs = try await fetchAppleScriptLibraryIDsForConfiguredScope()
        guard !libraryIDs.isEmpty else { return false }
        return !storedIDSet.isDisjoint(with: Set(libraryIDs))
    }

    public func verifyAndCleanDatabase(force: Bool = false) async throws -> DatabaseVerificationResult {
        let storedTracks = try await loadStoredTracksInConfiguredScope()
        guard !storedTracks.isEmpty else {
            return DatabaseVerificationResult(verifiedTrackCount: 0, removedTrackIDs: [])
        }

        if !force, shouldSkipDatabaseVerification() {
            return DatabaseVerificationResult(
                verifiedTrackCount: storedTracks.count,
                removedTrackIDs: [],
                skippedDueToRecentVerification: true
            )
        }

        let libraryIDs = try await fetchAppleScriptLibraryIDsForConfiguredScope()
        let libraryIDSet = Set(libraryIDs)
        let hasReadProvider = readProvider != nil

        guard !libraryIDSet.isEmpty else {
            log.warning("Database verification skipped because Music.app returned no track IDs")
            try updateDatabaseVerificationTimestamp()
            return DatabaseVerificationResult(
                verifiedTrackCount: storedTracks.count,
                removedTrackIDs: []
            )
        }

        let removedIDs = storedTracks.compactMap { track -> String? in
            LibrarySyncRemovalDecision.removedTrackID(
                for: track,
                libraryIDSet: libraryIDSet,
                hasReadProvider: hasReadProvider
            )
        }.sorted()
        for chunk in removedIDs.chunked(into: runtimeConfiguration.databaseVerificationBatchSize) {
            try await trackStore.deleteTrackIDs(chunk)
        }
        let removedIDSet = Set(removedIDs)
        let removedTracks = storedTracks.filter { removedIDSet.contains($0.id) }
        await invalidateCachesForLibraryChanges(
            hasLibraryChanges: !removedTracks.isEmpty,
            targets: cacheInvalidationTargets(removedTracks: removedTracks)
        )
        try await removeResolvedPrereleasePendingEntries(removedTracks: removedTracks)

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
                                \(result.refreshedTracks.count, privacy: .public) refreshed, \
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
        let storedByID = Dictionary(storedTracks.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let refreshedTracks = result.newTracks + result.modifiedTracks + result.identityChangedTracks + result
            .refreshedTracks
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
        try await removeResolvedPrereleasePendingEntries(
            removedTracks: result.removedTrackIDs.compactMap { storedByID[$0] }
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

    private func removeResolvedPrereleasePendingEntries(
        refreshedTracks: [Track],
        previousTracksByID: [String: Track]
    ) async throws {
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
        try await removeResolvedPrereleasePendingEntries(targets: targets)
    }

    private func removeResolvedPrereleasePendingEntries(removedTracks: [Track]) async throws {
        let removedAlbumIdentities = removedTracks
            .flatMap { track in
                AlbumIdentity.lookupCandidates(for: track)
                    .map { (artist: $0.artist, album: $0.album) }
            }
        let targets = normalizedCacheInvalidationTargets(removedAlbumIdentities)
        try await removeResolvedPrereleasePendingEntries(targets: targets)
    }

    private func removeResolvedPrereleasePendingEntries(
        targets: [(artist: String, album: String)]
    ) async throws {
        guard let pendingVerificationService else { return }
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
}
