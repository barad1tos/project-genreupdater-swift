import Core
import Foundation
import OSLog

/// Detects library changes and suggests updates for new/modified tracks.
///
/// Manual sync (all tiers): compare current library IDs against stored state.
/// Auto-sync (Pro only): periodic background polling with configurable interval.
public actor LibrarySyncService {
    let trackStore: any TrackStateStore
    private let effectDrain: MirrorEffectDrain?
    let observer: any MusicAppReading
    private var pendingVerificationService: (any PendingVerificationService)?
    var librarySnapshotService: (any LibrarySnapshotService)?
    private(set) var runtimeConfiguration: LibrarySyncRuntimeConfiguration
    let currentDate: @Sendable () -> Date
    private let log = Logger(subsystem: "com.genreupdater", category: "LibrarySyncService")

    public init(
        trackStore: any TrackStateStore,
        effectDrain: MirrorEffectDrain? = nil,
        pendingVerificationService: (any PendingVerificationService)? = nil,
        librarySnapshotService: (any LibrarySnapshotService)? = nil,
        runtimeConfiguration: LibrarySyncRuntimeConfiguration = LibrarySyncRuntimeConfiguration(),
        currentDate: @escaping @Sendable () -> Date = { Date() },
        observer: any MusicAppReading
    ) {
        self.trackStore = trackStore
        self.effectDrain = effectDrain
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
        let configuration = runtimeConfiguration
        return try await retryingSynchronizationConflicts {
            try await verificationAttempt(force: force, configuration: configuration)
        }
    }

    private func verificationAttempt(
        force: Bool,
        configuration: LibrarySyncRuntimeConfiguration
    ) async throws -> DatabaseVerificationResult {
        let snapshot = try await trackStore.loadMirrorSnapshot()
        let storedTracks = tracksInConfiguredScope(snapshot.presentTracks, configuration: configuration)
        guard !snapshot.presentIDs.isEmpty else {
            return DatabaseVerificationResult(verifiedTrackCount: 0, removedTrackIDs: [])
        }

        if !force, shouldSkipDatabaseVerification(configuration: configuration) {
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
            requestedTestArtists: configuration.testArtists,
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
        try Task.checkCancellation()
        let removedDatabaseIDs = snapshot.presentIDs
            .subtracting(observation.censusIDs)
            .sorted { $0.rawValue < $1.rawValue }
        let commitResult = try await commitInventory(
            observation,
            snapshot: snapshot,
            removedTracks: removedDatabaseIDs.compactMap { canonicalByID[$0] },
            syncRecordLimit: configuration.syncRecordLimit
        )
        let removedTracks = removedDatabaseIDs.compactMap { canonicalByID[$0] }
        await removeResolvedPrereleasePendingEntries(
            removedTracks: removedTracks,
            currentTracks: commitResult.snapshot.presentTracks
        )

        return finishVerification(
            configuration: configuration,
            verifiedTrackCount: storedTracks.count,
            removedIDs: removedDatabaseIDs
        )
    }

    private func finishVerification(
        configuration: LibrarySyncRuntimeConfiguration,
        verifiedTrackCount: Int,
        removedIDs: [MusicDatabaseTrackID]
    ) -> DatabaseVerificationResult {
        do {
            try updateDatabaseVerificationTimestamp(configuration: configuration)
        } catch {
            log.error(
                "Mirror verification committed but its timestamp could not be updated: \(error.localizedDescription, privacy: .private)"
            )
        }
        log.info(
            "Database verification complete: \(verifiedTrackCount, privacy: .public) verified, \(removedIDs.count, privacy: .public) removed"
        )
        return DatabaseVerificationResult(
            verifiedTrackCount: verifiedTrackCount,
            removedTrackIDs: removedIDs.map(\.rawValue)
        )
    }

    private func commitInventory(
        _ observation: LibraryObservation,
        snapshot: TrackMirrorSnapshot,
        removedTracks: [Track],
        syncRecordLimit: Int
    ) async throws -> MirrorCommitResult {
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
            window: MirrorSyncWindow(startedAt: observation.scope.createdAt, preparedAt: currentDate()),
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
        let effects = makeInventoryEffects(from: removedTracks, hasChanges: didChangeMembership || didObserveIdentity)
        let result = try await trackStore.commitMirror(MirrorCommit(
            baseRevision: snapshot.revision,
            observation: observationID,
            inventoryChange: inventoryTransition,
            repairs: [],
            upserts: [],
            certificates: certificateTransition,
            effects: effects,
            syncRecord: record,
            syncRecordLimit: syncRecordLimit
        ))
        await effectDrain?.drain(newlyCommittedEffectIDs: result.pendingEffectIDs)
        return result
    }

    /// Detect and persist Music.app library changes in the local store.
    ///
    /// - Parameter capturedScope: The initiating run's unbound scope. Its structure and normalized artists must match
    ///   the frozen runtime configuration. When omitted, the service captures a new scope from that configuration.
    /// - Returns: A result bound to the exact committed mirror revision and optional processing certificate.
    /// - Throws: `LibrarySyncObservationError` when captured scope or committed evidence is inconsistent.
    @discardableResult
    public func synchronizeNow(
        forceMetadataRefresh: Bool = false,
        capturedScope: ProcessingScopeSnapshot? = nil
    ) async throws -> SyncResult {
        let input = captureAttemptInput(
            forceMetadataRefresh: forceMetadataRefresh,
            capturedScope: capturedScope
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
        case .censusChanged, .generationChanged, .snapshotChanged:
            return true
        case .conflictingMetadata, .duplicateIdentity, .unexpectedMetadata, .unexpectedIdentity,
             .unresolvedMetadataIdentity, .identitySnapshotMismatch, .none:
            return false
        }
    }

    private func synchronizeAttempt(_ input: SyncAttemptInput) async throws -> SyncResult {
        let prepared = try await prepareAttempt(input)
        guard case let .prepared(detection) = prepared else {
            throw LibrarySyncObservationError.invalidObservation(detail: "synchronization was not prepared")
        }
        try Task.checkCancellation()
        let syncRecord = try makeSyncRecord(for: detection, startedAt: input.startedAt, preparedAt: currentDate())
        let projected = detection.result
        let effects = makeSyncEffects(
            from: projected,
            storedByID: detection.previousTracks,
            removedAliasTracks: detection.removedAliasTracks,
            hasMirrorMaintenance: !detection.repairs.isEmpty || !detection.retiredAliasIDs.isEmpty
        )
        let commitResult = try await trackStore.commitMirror(MirrorCommit(
            baseRevision: detection.baseRevision,
            observation: detection.observationID,
            inventoryChange: detection.inventoryChange,
            repairs: detection.repairs,
            retiredAliasIDs: detection.retiredAliasIDs,
            upserts: detection.upserts,
            certificates: detection.certificateChange,
            effects: effects,
            syncRecord: syncRecord,
            syncRecordLimit: input.configuration.syncRecordLimit
        ))
        let snapshot = commitResult.snapshot
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
        await effectDrain?.drain(newlyCommittedEffectIDs: commitResult.pendingEffectIDs)
        await removeResolvedPrereleasePendingEntries(
            refreshedTracks: result.modifiedTracks + result.identityChangedTracks,
            previousTracksByID: detection.previousTracks,
            currentTracks: committedSnapshot.presentTracks
        )
        await removeResolvedPrereleasePendingEntries(
            removedTracks: result.removedTrackIDs.compactMap { detection.previousTracks[$0] }
                + detection.removedAliasTracks,
            currentTracks: committedSnapshot.presentTracks
        )
        if committedDetection.didCompleteForceRefresh {
            do {
                try await updateForceScanDate(at: input.startedAt)
            } catch {
                log.error(
                    "Mirror committed but force-scan cache metadata could not be updated: \(error.localizedDescription, privacy: .private)"
                )
            }
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
        let newTracks = try committedTracks(projected.newTracks, in: tracksByID)
        let modifiedTracks = try committedTracks(projected.modifiedTracks, in: tracksByID)
        let identityChangedTracks = try committedTracks(projected.identityChangedTracks, in: tracksByID)
        let refreshedTracks = try committedTracks(projected.refreshedTracks, in: tracksByID)
        guard projected.removedTrackIDs.allSatisfy({ tracksByID[$0] == nil }) else {
            throw LibrarySyncObservationError.invalidObservation(
                detail: "committed mirror retained a track classified as removed"
            )
        }
        return SyncResult(
            newTracks: newTracks,
            modifiedTracks: modifiedTracks,
            identityChangedTracks: identityChangedTracks,
            refreshedTracks: refreshedTracks,
            removedTrackIDs: projected.removedTrackIDs,
            mirrorMaintenanceCount: detection.repairs.reduce(0) { count, repair in
                count + repair.sourceIDs.count
            } + detection.retiredAliasIDs.count,
            scope: detection.scope.binding(
                revision: snapshot.revision,
                certificateID: detection.syncEvidence.certificateID
            )
        )
    }

    private func committedTracks(
        _ projected: [Track],
        in tracksByID: [String: Track]
    ) throws -> [Track] {
        try projected.map { track in
            guard let committed = tracksByID[track.id] else {
                throw LibrarySyncObservationError.invalidObservation(
                    detail: "committed mirror omitted accepted track \(track.id)"
                )
            }
            return committed
        }
    }

    private func makeSyncRecord(
        for detection: SyncDetection,
        startedAt: Date,
        preparedAt: Date
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
            window: MirrorSyncWindow(startedAt: startedAt, preparedAt: preparedAt),
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

    private func makeInventoryEffects(from removedTracks: [Track], hasChanges: Bool) -> [MirrorEffect] {
        makeMirrorEffects(
            hasLibraryChanges: hasChanges,
            targets: cacheInvalidationTargets(removedTracks: removedTracks)
        )
    }

    private func makeSyncEffects(
        from result: SyncResult,
        storedByID: [String: Track],
        removedAliasTracks: [Track],
        hasMirrorMaintenance: Bool
    ) -> [MirrorEffect] {
        makeMirrorEffects(
            hasLibraryChanges: result.hasChanges || hasMirrorMaintenance,
            targets: cacheInvalidationTargets(
                newTracks: result.newTracks,
                modifiedTracks: result.modifiedTracks,
                identityChangedTracks: result.identityChangedTracks,
                removedTrackIDs: result.removedTrackIDs,
                removedAliasTracks: removedAliasTracks,
                storedByID: storedByID
            )
        )
    }

    private func makeMirrorEffects(
        hasLibraryChanges: Bool,
        targets: [(artist: String, album: String)]
    ) -> [MirrorEffect] {
        guard hasLibraryChanges else { return [] }
        return targets.flatMap { target in
            let identity = AlbumIdentity(artist: target.artist, album: target.album)
            let targetEffects: [MirrorEffect] = [
                .invalidateAlbumYear(identity),
                .invalidateAPIResults(identity),
            ]
            return targetEffects
        } + [.invalidateSnapshot, .refreshProjections]
    }

    private func cacheInvalidationTargets(
        newTracks: [Track] = [],
        modifiedTracks: [Track] = [],
        identityChangedTracks: [Track] = [],
        removedTrackIDs: [String] = [],
        removedAliasTracks: [Track] = [],
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
        candidates.append(contentsOf: cacheInvalidationTargets(removedTracks: removedAliasTracks))

        return normalizedCacheInvalidationTargets(candidates)
    }

    private func cacheInvalidationTargets(removedTracks: [Track]) -> [(artist: String, album: String)] {
        normalizedCacheInvalidationTargets(
            removedTracks.flatMap { cacheInvalidationTargets(for: $0) }
        )
    }

    private func removeResolvedPrereleasePendingEntries(
        refreshedTracks: [Track],
        previousTracksByID: [String: Track],
        currentTracks: [Track]
    ) async {
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
        await removeResolvedPrereleasePendingEntries(targets: targets, currentTracks: currentTracks)
    }

    private func removeResolvedPrereleasePendingEntries(
        removedTracks: [Track],
        currentTracks: [Track]
    ) async {
        let removedAlbumIdentities = removedTracks
            .flatMap { track in
                AlbumIdentity.lookupCandidates(for: track)
                    .map { (artist: $0.artist, album: $0.album) }
            }
        let targets = normalizedCacheInvalidationTargets(removedAlbumIdentities)
        await removeResolvedPrereleasePendingEntries(targets: targets, currentTracks: currentTracks)
    }

    private func removeResolvedPrereleasePendingEntries(
        targets: [(artist: String, album: String)],
        currentTracks: [Track]
    ) async {
        guard let pendingVerificationService else { return }
        guard !targets.isEmpty else { return }

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

    private func shouldSkipDatabaseVerification(
        configuration: LibrarySyncRuntimeConfiguration,
        now: Date = Date()
    ) -> Bool {
        guard configuration.databaseVerificationIntervalDays > 0 else {
            return false
        }

        let timestampURL = databaseVerificationTimestampURL(configuration: configuration)
        guard
            let timestamp = try? String(contentsOf: timestampURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let lastVerification = Self.iso8601Formatter.date(from: timestamp)
        else {
            return false
        }

        let elapsed = now.timeIntervalSince(lastVerification)
        let requiredInterval = TimeInterval(configuration.databaseVerificationIntervalDays) * 86400
        return elapsed < requiredInterval
    }

    private func updateDatabaseVerificationTimestamp(
        configuration: LibrarySyncRuntimeConfiguration,
        now: Date = Date()
    ) throws {
        let timestampURL = databaseVerificationTimestampURL(configuration: configuration)
        try FileManager.default.createDirectory(
            at: timestampURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let timestamp = Self.iso8601Formatter.string(from: now)
        try timestamp.write(to: timestampURL, atomically: true, encoding: .utf8)
    }

    private func databaseVerificationTimestampURL(configuration: LibrarySyncRuntimeConfiguration) -> URL {
        let logsDirectory = Self.resolvedURL(path: configuration.logsBaseDirectory)
        return Self.resolvedURL(
            path: configuration.lastDatabaseVerifyLog,
            relativeTo: logsDirectory
        )
    }

    private static var iso8601Formatter: ISO8601DateFormatter {
        ISO8601DateFormatter()
    }
}
