import Core
import Foundation
import OSLog

/// Detects library changes and suggests updates for new/modified tracks.
///
/// Manual sync (all tiers): compare current library IDs against stored state.
/// Auto-sync (Pro only): periodic background polling with configurable interval.
public actor LibrarySyncService {
    let trackStore: any TrackStateStore
    private let cache: (any CacheService)?
    let observer: any MusicAppReading
    private var pendingVerificationService: (any PendingVerificationService)?
    var librarySnapshotService: (any LibrarySnapshotService)?
    private(set) var runtimeConfiguration: LibrarySyncRuntimeConfiguration
    let currentDate: @Sendable () -> Date
    private let log = Logger(subsystem: "com.genreupdater", category: "LibrarySyncService")

    public init(
        trackStore: any TrackStateStore,
        cache: (any CacheService)? = nil,
        pendingVerificationService: (any PendingVerificationService)? = nil,
        librarySnapshotService: (any LibrarySnapshotService)? = nil,
        runtimeConfiguration: LibrarySyncRuntimeConfiguration = LibrarySyncRuntimeConfiguration(),
        currentDate: @escaping @Sendable () -> Date = { Date() },
        observer: any MusicAppReading
    ) {
        self.trackStore = trackStore
        self.cache = cache
        self.observer = observer
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

    /// Runs automatic database verification when the live schedule is enabled.
    public func runScheduledVerification() async throws -> DatabaseVerificationResult? {
        guard runtimeConfiguration.databaseVerificationIntervalDays > 0 else {
            return nil
        }
        return try await verifyAndCleanDatabase(force: false)
    }

    public func verifyAndCleanDatabase(force: Bool = false) async throws -> DatabaseVerificationResult {
        try await retryingSynchronizationConflicts {
            try await verificationAttempt(force: force)
        }
    }

    private func verificationAttempt(force: Bool) async throws -> DatabaseVerificationResult {
        let snapshot = try await trackStore.loadMirrorSnapshot()
        let storedTracks = tracksInConfiguredScope(snapshot.presentTracks)
        guard !snapshot.presentIDs.isEmpty else {
            return DatabaseVerificationResult(verifiedTrackCount: 0, removedTrackIDs: [])
        }

        if !force, shouldSkipDatabaseVerification() {
            return DatabaseVerificationResult(
                verifiedTrackCount: storedTracks.count,
                removedTrackIDs: [],
                skippedDueToRecentVerification: true
            )
        }

        let scopedByID = try canonicalMirror(storedTracks)
        let canonicalByID = try canonicalMirror(snapshot.presentTracks)
        guard let mirror = LibraryMirrorIndex(tracksByID: scopedByID) else {
            throw LibrarySyncObservationError.invalidObservation(detail: "stored mirror index is inconsistent")
        }
        guard let inventory = LibraryInventoryIndex(identitiesByID: snapshot.memberIdentities) else {
            throw LibrarySyncObservationError.invalidObservation(detail: "stored inventory index is inconsistent")
        }
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: runtimeConfiguration.testArtists,
            knownTrackCount: storedTracks.count,
            createdAt: currentDate(),
            reason: "database verification"
        )
        let request = LibraryObservationRequest(
            scope: scope,
            refresh: .membershipOnly,
            previous: .verified(mirror),
            inventory: inventory
        )
        let observation = try await observer.observe(request)
        try validate(observation, request: request)
        let removedDatabaseIDs = snapshot.presentIDs
            .subtracting(observation.censusIDs)
            .sorted { $0.rawValue < $1.rawValue }
        try await commitInventory(observation, snapshot: snapshot)
        let removedTracks = removedDatabaseIDs.compactMap { canonicalByID[$0] }
        await invalidateCachesForLibraryChanges(
            hasLibraryChanges: !removedTracks.isEmpty,
            targets: cacheInvalidationTargets(removedTracks: removedTracks)
        )
        try await removeResolvedPrereleasePendingEntries(removedTracks: removedTracks)

        try updateDatabaseVerificationTimestamp()
        log.info(
            "Database verification complete: \(storedTracks.count, privacy: .public) verified, \(removedDatabaseIDs.count, privacy: .public) removed"
        )

        return DatabaseVerificationResult(
            verifiedTrackCount: storedTracks.count,
            removedTrackIDs: removedDatabaseIDs.map(\.rawValue)
        )
    }

    private func commitInventory(
        _ observation: LibraryObservation,
        snapshot: TrackMirrorSnapshot
    ) async throws {
        let inventoryTransition: InventoryChange
        let certificateTransition: CertificateChange
        let didChangeMembership = observation.censusIDs != snapshot.presentIDs
        let didObserveIdentity = !observation.identities.isEmpty
        if !didChangeMembership, !didObserveIdentity {
            inventoryTransition = .preserve
            certificateTransition = .preserve
        } else {
            inventoryTransition = try inventoryChange(for: observation)
            certificateTransition = didChangeMembership
                ? .invalidate(.membershipChanged)
                : .invalidate(.incompleteObservation)
        }
        let observationID = ObservationID()
        let membership = try MembershipFingerprint.make(ids: Array(observation.censusIDs))
        let removedCount = snapshot.presentIDs.subtracting(observation.censusIDs).count
        let record = try MirrorSyncRecord(
            observation: observationID,
            revisions: MirrorSyncRevisions(
                base: snapshot.revision,
                committed: snapshot.revision.advanced()
            ),
            evidence: MirrorSyncEvidence(
                membership: membership,
                scopeID: observation.scope.id,
                certificateID: nil
            ),
            mode: .membershipOnly,
            window: MirrorSyncWindow(startedAt: observation.scope.createdAt, completedAt: currentDate()),
            delta: MirrorSyncCounts(
                new: 0,
                modified: 0,
                identityChanged: 0,
                refreshed: 0,
                removed: removedCount
            ),
            coverage: MirrorSyncCoverage(
                identityRequestedCount: observation.identity.requestedIDs.count,
                identityObservedCount: observation.identity.observedIDs.count,
                metadataRequestedCount: observation.metadata.requestedIDs.count,
                metadataObservedCount: observation.metadata.observedIDs.count,
                isMembershipComplete: hasCompleteMembership(observation),
                isIdentityComplete: observation.identity.isComplete,
                isMetadataComplete: observation.metadata.isComplete
            )
        )
        try await trackStore.commitMirror(MirrorCommit(
            baseRevision: snapshot.revision,
            observation: observationID,
            inventoryChange: inventoryTransition,
            repairs: [],
            upserts: [],
            certificates: certificateTransition,
            syncRecord: record
        ))
    }

    /// Detect and persist Music.app library changes in the local store.
    /// A captured scope preserves the initiating run's identity while synchronization binds committed evidence to it.
    @discardableResult
    public func synchronizeNow(
        forceMetadataRefresh: Bool = false,
        capturedScope: ProcessingScopeSnapshot? = nil
    ) async throws -> SyncResult {
        let input = SyncAttemptInput(
            configuration: runtimeConfiguration,
            capturedScope: capturedScope ?? runtimeConfiguration.capturedScope,
            startedAt: currentDate(),
            isForced: forceMetadataRefresh
        )
        return try await retryingSynchronizationConflicts(policy: input.configuration.mirrorRetryPolicy) {
            try await synchronizeAttempt(input)
        }
    }

    private func retryingSynchronizationConflicts<Result: Sendable>(
        policy: MirrorRetryPolicy? = nil,
        _ operation: () async throws -> Result
    ) async throws -> Result {
        let policy = policy ?? runtimeConfiguration.mirrorRetryPolicy
        var conflictCount = 0
        while true {
            do {
                return try await operation()
            } catch let conflict where isRetryableSynchronizationConflict(conflict) {
                guard conflictCount < policy.retryLimit else {
                    throw conflict
                }
                conflictCount += 1
                try await Task.sleep(for: policy.delay)
            }
        }
    }

    private func isRetryableSynchronizationConflict(_ error: any Error) -> Bool {
        if error is MirrorRevisionConflict {
            return true
        }
        switch error as? MusicAppObservationError {
        case .censusChanged, .generationChanged:
            return true
        case .duplicateMetadata, .duplicateIdentity, .unexpectedMetadata, .unexpectedIdentity,
             .unresolvedMetadataIdentity, .none:
            return false
        }
    }

    private func synchronizeAttempt(_ input: SyncAttemptInput) async throws -> SyncResult {
        let prepared = try await prepareAttempt(input)
        guard case let .prepared(detection) = prepared else {
            throw LibrarySyncObservationError.invalidObservation(detail: "synchronization was not prepared")
        }
        try Task.checkCancellation()
        let syncRecord = try makeSyncRecord(
            for: detection,
            startedAt: input.startedAt,
            completedAt: currentDate()
        )
        let commitResult = try await trackStore.commitMirror(MirrorCommit(
            baseRevision: detection.baseRevision,
            observation: detection.observationID,
            inventoryChange: detection.inventoryChange,
            repairs: detection.repairs,
            upserts: detection.upserts,
            certificates: detection.certificateChange,
            syncRecord: syncRecord
        ))
        let snapshot = if let committedSnapshot = commitResult.snapshot {
            committedSnapshot
        } else {
            try await trackStore.loadMirrorSnapshot()
        }
        guard snapshot.revision == commitResult.revision else {
            throw LibrarySyncObservationError.invalidObservation(
                detail: "committed mirror revision does not match its result"
            )
        }
        let committed = try prepared.transitioned(by: .committed(commitResult, snapshot))
        guard case let .committed(committedDetection, _, committedSnapshot) = committed else {
            throw LibrarySyncObservationError.invalidObservation(detail: "synchronization was not committed")
        }
        let result = try committedResult(from: committedDetection, snapshot: committedSnapshot)

        await invalidateCachesForLibraryChanges(
            hasLibraryChanges: result.hasChanges,
            targets: cacheInvalidationTargets(
                newTracks: result.newTracks,
                modifiedTracks: result.modifiedTracks,
                identityChangedTracks: result.identityChangedTracks,
                removedTrackIDs: result.removedTrackIDs,
                storedByID: detection.previousTracks
            )
        )
        try await removeResolvedPrereleasePendingEntries(
            refreshedTracks: result.modifiedTracks + result.identityChangedTracks,
            previousTracksByID: detection.previousTracks
        )
        try await removeResolvedPrereleasePendingEntries(
            removedTracks: result.removedTrackIDs.compactMap { detection.previousTracks[$0] }
        )
        if committedDetection.didCompleteForceRefresh {
            try await updateForceScanDate(at: input.startedAt)
        }
        return result
    }

    private func committedResult(
        from detection: SyncDetection,
        snapshot: TrackMirrorSnapshot
    ) throws -> SyncResult {
        if let certificateID = detection.syncEvidence.certificateID,
           !snapshot.certificates.contains(where: { $0.id == certificateID }) {
            throw LibrarySyncObservationError.invalidObservation(
                detail: "committed scope certificate is absent from its mirror snapshot"
            )
        }
        let tracksByID = Dictionary(uniqueKeysWithValues: snapshot.presentTracks.map { ($0.id, $0) })
        let projected = detection.result
        return SyncResult(
            newTracks: projected.newTracks.compactMap { tracksByID[$0.id] },
            modifiedTracks: projected.modifiedTracks.compactMap { tracksByID[$0.id] },
            identityChangedTracks: projected.identityChangedTracks.compactMap { tracksByID[$0.id] },
            refreshedTracks: projected.refreshedTracks.compactMap { tracksByID[$0.id] },
            removedTrackIDs: projected.removedTrackIDs.filter { tracksByID[$0] == nil },
            scope: detection.scope.binding(
                revision: snapshot.revision,
                certificateID: detection.syncEvidence.certificateID
            )
        )
    }

    private func makeSyncRecord(
        for detection: SyncDetection,
        startedAt: Date,
        completedAt: Date
    ) throws -> MirrorSyncRecord {
        let result = detection.result
        return try MirrorSyncRecord(
            observation: detection.observationID,
            revisions: MirrorSyncRevisions(
                base: detection.baseRevision,
                committed: detection.baseRevision.advanced()
            ),
            evidence: detection.syncEvidence,
            mode: detection.syncMode,
            window: MirrorSyncWindow(startedAt: startedAt, completedAt: completedAt),
            delta: MirrorSyncCounts(
                new: result.newTracks.count,
                modified: result.modifiedTracks.count,
                identityChanged: result.identityChangedTracks.count,
                refreshed: result.refreshedTracks.count,
                removed: result.removedTrackIDs.count
            ),
            coverage: detection.syncCoverage
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
