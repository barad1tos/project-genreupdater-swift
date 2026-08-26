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
        try await retryingMirrorConflicts {
            try await verificationAttempt(force: force)
        }
    }

    private func verificationAttempt(force: Bool) async throws -> DatabaseVerificationResult {
        let snapshot = try await trackStore.loadMirrorSnapshot()
        let storedTracks = tracksInConfiguredScope(snapshot.tracks)
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

        let scopedByID = try canonicalMirror(storedTracks)
        guard let mirror = LibraryMirrorIndex(tracksByID: scopedByID) else {
            throw LibrarySyncObservationError.invalidObservation(detail: "stored mirror index is inconsistent")
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
            previous: .verified(mirror)
        )
        let observation = try await observer.observe(request)
        try validate(observation, request: request)
        if case .scoped = observation.membership,
           !observation.currentIDs.isSubset(of: Set(scopedByID.keys)) {
            throw LibrarySyncObservationError.invalidObservation(
                detail: "membership-only scoped result contains an ID outside its previous mirror"
            )
        }

        let removedDatabaseIDs = Set(scopedByID.keys)
            .subtracting(observation.censusIDs)
            .sorted { $0.rawValue < $1.rawValue }
        if !removedDatabaseIDs.isEmpty {
            try await applyMirrorDeletions(removedDatabaseIDs, baseRevision: snapshot.revision)
        }
        let removedIDSet = Set(removedDatabaseIDs)
        let removedTracks = storedTracks.filter { track in
            track.databaseID.map(removedIDSet.contains) ?? false
        }
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

    private func applyMirrorDeletions(
        _ ids: [MusicDatabaseTrackID],
        baseRevision: MirrorRevision
    ) async throws {
        try await trackStore.applyMirror(TrackMirrorUpdate(
            baseRevision: baseRevision,
            coverageChange: .preserve,
            repairs: [],
            upserts: [],
            deletions: ids
        ))
    }

    /// Detect and persist Music.app library changes in the local store.
    @discardableResult
    public func synchronizeNow(forceMetadataRefresh: Bool = false) async throws -> SyncResult {
        try await retryingMirrorConflicts {
            try await synchronizeAttempt(forceMetadataRefresh: forceMetadataRefresh)
        }
    }

    private func retryingMirrorConflicts<Result: Sendable>(
        _ operation: () async throws -> Result
    ) async throws -> Result {
        var conflictCount = 0
        while true {
            do {
                return try await operation()
            } catch let conflict as MirrorRevisionConflict {
                guard conflictCount < runtimeConfiguration.mirrorRetryPolicy.retryLimit else {
                    throw conflict
                }
                conflictCount += 1
                try await Task.sleep(for: runtimeConfiguration.mirrorRetryPolicy.delay)
            }
        }
    }

    private func synchronizeAttempt(forceMetadataRefresh: Bool) async throws -> SyncResult {
        let detection = try await detectObservation(forceMetadataRefresh: forceMetadataRefresh)
        let result = detection.result
        try await trackStore.applyMirror(TrackMirrorUpdate(
            baseRevision: detection.baseRevision,
            coverageChange: detection.coverageChange,
            repairs: detection.repairs,
            upserts: detection.upserts,
            deletions: detection.removedIDs
        ))

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
        if detection.didCompleteForceRefresh {
            try await updateForceScanDate()
        }
        return result
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
