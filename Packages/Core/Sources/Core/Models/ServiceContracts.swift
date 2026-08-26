import Foundation

/// Protocol for cache operations (in-memory + persistent).
public protocol CacheService: Actor, Sendable {
    func initialize() async throws
    func get<T: Codable & Sendable>(key: String) async -> T?
    func set(key: String, value: some Codable & Sendable, ttl: TimeInterval?) async
    func invalidate(key: String) async
    func clear() async
    func getAlbumYear(artist: String, album: String) async -> AlbumCacheEntry?
    func storeAlbumYear(artist: String, album: String, year: Int, confidence: Int) async
    func invalidateAlbum(artist: String, album: String) async
    func invalidateAllAlbumYears() async
    func getCachedAPIResult(artist: String, album: String, source: String) async -> CachedAPIResult?
    func setCachedAPIResult(_ result: CachedAPIResult) async
    func invalidateCachedAPIResults(artist: String, album: String) async
    func syncToDisk() async throws
}

/// Cache capability for values that must not expire by time.
public protocol PersistentCacheService: CacheService {
    /// Stores a value without time-based expiry; it remains removable by `invalidate(key:)`, `clear()`, or capacity
    /// eviction.
    func setPersistent(key: String, value: some Codable & Sendable) async
}

public enum TrackStoreError: LocalizedError, Sendable, Equatable {
    case missingTrack(id: String)
    case missingDatabaseID(trackID: String)
    case nonCanonicalTrack(trackID: String, databaseID: MusicDatabaseTrackID)
    case emptySource
    case duplicateRepairSources(ids: [String])
    case duplicateRepairTargets(ids: [MusicDatabaseTrackID])
    case redundantRepair(id: MusicDatabaseTrackID)
    case missingSource(id: String)
    case targetExists(id: MusicDatabaseTrackID)
    case duplicateUpserts(ids: [MusicDatabaseTrackID])
    case duplicateMembershipIDs(ids: [MusicDatabaseTrackID])
    case invalidMembershipIDs(ids: [String])
    case membershipStampMismatch(expected: MembershipStamp, actual: MembershipStamp)
    case operationsOutsideMembership(ids: [MusicDatabaseTrackID])
    case identityOverlap(ids: [MusicDatabaseTrackID])
    case identityCollisions(ids: [MusicDatabaseTrackID])

    public var errorDescription: String? {
        switch self {
        case let .missingTrack(id):
            "Track state store has no track with ID \(id)"
        case let .missingDatabaseID(trackID):
            "Track mirror upsert has no Music database ID for track ID \(trackID)"
        case let .nonCanonicalTrack(trackID, databaseID):
            "Track mirror upsert ID \(trackID) does not match Music database ID \(databaseID.rawValue)"
        case .emptySource:
            "Track mirror repair has an empty legacy source ID"
        case let .duplicateRepairSources(ids):
            "Track mirror update contains duplicate repair sources: \(ids.joined(separator: ", "))"
        case let .duplicateRepairTargets(ids):
            "Track mirror update contains duplicate repair targets: \(ids.map(\.rawValue).joined(separator: ", "))"
        case let .redundantRepair(id):
            "Track mirror repair target \(id.rawValue) is already canonical"
        case let .missingSource(id):
            "Track mirror repair has no stored source with ID \(id)"
        case let .targetExists(id):
            "Track mirror repair target already exists with ID \(id.rawValue)"
        case let .duplicateUpserts(ids):
            "Track mirror update contains duplicate upsert IDs: \(ids.map(\.rawValue).joined(separator: ", "))"
        case let .duplicateMembershipIDs(ids):
            "Track mirror update contains duplicate membership IDs: \(ids.map(\.rawValue).joined(separator: ", "))"
        case let .invalidMembershipIDs(ids):
            "Stored track mirror membership contains invalid IDs: \(ids.joined(separator: ", "))"
        case let .membershipStampMismatch(expected, actual):
            "Track mirror membership stamp \(actual.fingerprint) does not match expected \(expected.fingerprint)"
        case let .operationsOutsideMembership(ids):
            "Track mirror operations target IDs outside current membership: \(ids.map(\.rawValue).joined(separator: ", "))"
        case let .identityOverlap(ids):
            "Track mirror update contains overlapping operation IDs: \(ids.map(\.rawValue).joined(separator: ", "))"
        case let .identityCollisions(ids):
            "Track mirror upserts collide with noncanonical stored IDs: \(ids.map(\.rawValue).joined(separator: ", "))"
        }
    }
}

/// Repairs one legacy persisted row to its authoritative Music database identity.
public struct TrackMirrorRepair: Sendable {
    public let sourceID: String
    public let target: Track

    public init(sourceID: String, target: Track) {
        self.sourceID = sourceID
        self.target = target
    }
}

/// Processing scope proven by one complete Music library observation.
public struct MirrorScope: Codable, Sendable {
    public static let fullLibrary = Self(testArtists: [])

    public let testArtists: [String]

    public var isFullLibrary: Bool {
        testArtists.isEmpty
    }

    public init(testArtists: [String]) {
        self.testArtists = ArtistAllowList.normalized(testArtists).sorted { first, second in
            let comparison = first.localizedCaseInsensitiveCompare(second)
            return comparison == .orderedSame ? first < second : comparison == .orderedAscending
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(testArtists: container.decode([String].self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(testArtists)
    }
}

extension MirrorScope: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.testArtists.count == rhs.testArtists.count else { return false }
        return zip(lhs.testArtists, rhs.testArtists).allSatisfy { first, second in
            first.localizedCaseInsensitiveCompare(second) == .orderedSame
        }
    }
}

/// Persisted evidence for which processing scope the mirror can authorize.
public enum MirrorCoverage: Equatable, Sendable {
    case unknown
    case verified(MirrorScope)

    public func admits(_ requestedScope: MirrorScope) -> Bool {
        guard case let .verified(verifiedScope) = self else { return false }
        guard !verifiedScope.isFullLibrary else { return true }
        guard !requestedScope.isFullLibrary else { return false }
        return requestedScope.testArtists.allSatisfy { requestedArtist in
            ArtistAllowList.containsNormalized(requestedArtist, in: verifiedScope.testArtists)
        }
    }

    public func applying(_ change: MirrorCoverageChange) -> Self {
        switch change {
        case .preserve:
            self
        case let .replace(scope):
            .verified(scope)
        case .invalidate:
            .unknown
        }
    }
}

/// Evidence transition committed atomically with one mirror mutation.
public enum MirrorCoverageChange: Equatable, Sendable {
    case preserve
    case replace(MirrorScope)
    case invalidate
}

/// The canonical-library membership evidence carried by a mirror mutation.
public enum MembershipChange: Equatable, Sendable {
    case preserve
    case replace(stamp: MembershipStamp, ids: [MusicDatabaseTrackID], observedAt: Date)
}

/// One coherent mutation of the persisted Music library mirror.
public struct TrackMirrorUpdate: Sendable {
    public let baseRevision: MirrorRevision
    public let coverageChange: MirrorCoverageChange
    public let membershipChange: MembershipChange
    public let repairs: [TrackMirrorRepair]
    public let upserts: [Track]

    public init(
        baseRevision: MirrorRevision,
        coverageChange: MirrorCoverageChange,
        membershipChange: MembershipChange,
        repairs: [TrackMirrorRepair],
        upserts: [Track]
    ) {
        self.baseRevision = baseRevision
        self.coverageChange = coverageChange
        self.membershipChange = membershipChange
        self.repairs = repairs
        self.upserts = upserts
    }
}

/// One coherent read of current library membership, repair input, and scope evidence.
public struct TrackMirrorSnapshot: Equatable, Sendable {
    public let revision: MirrorRevision
    public let membershipStamp: MembershipStamp
    public let presentTracks: [Track]
    public let repairCandidates: [Track]
    public let coverage: MirrorCoverage

    public init(
        revision: MirrorRevision,
        membershipStamp: MembershipStamp,
        presentTracks: [Track],
        repairCandidates: [Track],
        coverage: MirrorCoverage
    ) {
        self.revision = revision
        self.membershipStamp = membershipStamp
        self.presentTracks = presentTracks
        self.repairCandidates = repairCandidates
        self.coverage = coverage
    }
}

/// Protocol for persisting the track metadata mirror and processing state.
public protocol TrackStateStore: Actor {
    func initialize() async throws
    func loadAllTracks() async throws -> [Track]
    func loadMirrorSnapshot() async throws -> TrackMirrorSnapshot
    /// Atomically applies one coherent metadata-mirror update.
    @discardableResult
    func applyMirror(_ update: TrackMirrorUpdate) async throws -> MirrorRevision
    func getTrack(byID id: String) async throws -> Track?
    func getHistoricalTrack(byID id: String) async throws -> Track?
    /// Atomically persists metadata and processing flags for a change keyed by
    /// the canonical Music.app database ID. Legacy read IDs are migration input,
    /// not valid identities for newly applied changes.
    func persistAppliedChange(_ change: ChangeLogEntry) async throws
    func getUnprocessedTracks() async throws -> [Track]
    func trackCount() async throws -> Int
}

extension TrackStateStore {
    public func getHistoricalTrack(byID id: String) async throws -> Track? {
        try await getTrack(byID: id)
    }
}

/// Protocol for external music metadata API clients.
public protocol ExternalAPIService: Sendable {
    func getAlbumYear(
        artist: String,
        album: String,
        currentLibraryYear: Int?,
        earliestTrackAddedYear: Int?
    ) async throws -> YearResult

    func getReleaseCandidates(
        artist: String,
        album: String,
        currentLibraryYear: Int?,
        earliestTrackAddedYear: Int?
    ) async throws -> [ReleaseCandidate]

    func getArtistActivityPeriod(normalizedArtist: String) async throws -> (start: Int?, end: Int?)
    func getArtistStartYear(normalizedArtist: String) async throws -> Int?
    /// The artist's region NAME for release-country scoring; nil when
    /// the lookup SUCCEEDED but found no region (cacheable miss). A
    /// transport/decoding failure THROWS so callers never confuse it
    /// with a confirmed absence. Only MusicBrainz answers.
    func getArtistRegion(artist: String) async throws -> String?
    func initialize(force: Bool) async throws
    func close() async
}

extension ExternalAPIService {
    public func getReleaseCandidates(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> [ReleaseCandidate] {
        []
    }

    public func initialize(force: Bool = false) async throws {
        try await initialize(force: force)
    }

    public func close() async {
        // Services without retained connections have nothing to release.
    }

    public func getArtistRegion(artist _: String) async throws -> String? {
        nil
    }
}

/// Protocol for managing albums that need manual year verification.
public protocol PendingVerificationService: Actor, Sendable {
    func initialize() async throws
    func markForVerification(
        artist: String,
        album: String,
        reason: String,
        metadata: [String: String]?,
        recheckDays: Int?
    ) async
    func removeFromPending(artist: String, album: String) async
    func getEntry(artist: String, album: String) async -> PendingAlbumEntry?
    func getAttemptCount(artist: String, album: String) async -> Int
    func isVerificationNeeded(artist: String, album: String) async -> Bool
    func getAllPendingAlbums() async -> [PendingAlbumEntry]
    func getPendingAlbums(reason: String) async -> [PendingAlbumEntry]
    func getDuePendingAlbums() async -> [PendingAlbumEntry]
    func getPendingVerificationSnapshot() async -> (all: [PendingAlbumEntry], due: [PendingAlbumEntry])
    func getProblematicPendingAlbums(minAttempts: Int) async -> [ProblematicPendingAlbum]
    func shouldAutoVerify() async -> Bool
    func updateVerificationTimestamp() async throws
}

extension PendingVerificationService {
    public func getDuePendingAlbums() async -> [PendingAlbumEntry] {
        let allEntries = await getAllPendingAlbums()
        return await duePendingAlbums(from: allEntries)
    }

    public func getPendingVerificationSnapshot() async -> (all: [PendingAlbumEntry], due: [PendingAlbumEntry]) {
        let allEntries = await getAllPendingAlbums()
        let dueEntries = await duePendingAlbums(from: allEntries)
        return (allEntries, dueEntries)
    }

    public func getPendingAlbums(reason: String) async -> [PendingAlbumEntry] {
        let normalizedReason = normalizedPendingVerificationReason(reason)
        return await getAllPendingAlbums().filter {
            normalizedPendingVerificationReason($0.reason) == normalizedReason
        }
    }

    public func getProblematicPendingAlbums(minAttempts _: Int) async -> [ProblematicPendingAlbum] {
        []
    }

    private func duePendingAlbums(from entries: [PendingAlbumEntry]) async -> [PendingAlbumEntry] {
        var dueEntries: [PendingAlbumEntry] = []
        for entry in entries {
            let isDue = await isVerificationNeeded(artist: entry.artist, album: entry.album)
            guard isDue else { continue }
            dueEntries.append(entry)
        }
        return dueEntries
    }
}

private func normalizedPendingVerificationReason(_ reason: String) -> String {
    let normalizedReason = reason
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "-", with: "_")
        .lowercased()
    return normalizedReason == "pre_release" ? "prerelease" : normalizedReason
}

/// Token-bucket rate limiter for API calls.
public protocol RateLimiter: Actor {
    func acquire() async -> Duration
    func release()
    func getStats() -> RateLimiterStats
}

public struct RateLimiterStats: Sendable {
    public let totalRequests: Int
    public let totalWaitTime: Duration
    public let currentTokens: Int

    public init(totalRequests: Int, totalWaitTime: Duration, currentTokens: Int) {
        self.totalRequests = totalRequests
        self.totalWaitTime = totalWaitTime
        self.currentTokens = currentTokens
    }
}

/// Protocol for library snapshot persistence.
public protocol LibrarySnapshotService: Actor {
    func loadSnapshot() async throws -> [Track]?
    func saveSnapshot(_ tracks: [Track]) async throws -> String
    /// Invalidates cached tracks while retaining all snapshot metadata, including the force-refresh schedule.
    func clearSnapshot() async
    func isSnapshotValid() async -> Bool
    func getSnapshotMetadata() async -> LibraryCacheMetadata?
    func updateSnapshotMetadata(_ metadata: LibraryCacheMetadata) async throws
    func getLibraryModificationDate() async throws -> Date
    var isEnabled: Bool { get }
}

/// Protocol for track processing operations.
public protocol TrackProcessor: Sendable {
    func updateArtist(
        track: Track,
        newArtistName: String,
        originalArtist: String?,
        updateAlbumArtist: Bool
    ) async throws -> Bool
}

extension TrackProcessor {
    public func updateArtist(
        track: Track,
        newArtistName: String,
        originalArtist: String? = nil,
        updateAlbumArtist: Bool = true
    ) async throws -> Bool {
        try await updateArtist(
            track: track,
            newArtistName: newArtistName,
            originalArtist: originalArtist,
            updateAlbumArtist: updateAlbumArtist
        )
    }
}

public protocol ChangeLogStore: Actor {
    func saveEntry(_ entry: ChangeLogEntry) async throws
    func saveEntries(_ entries: [ChangeLogEntry]) async throws
    func loadAll() async throws -> [ChangeLogEntry]
    /// Newest-first bounded read for display surfaces; `loadAll` stays
    /// the undo/audit path.
    func loadRecent(limit: Int) async throws -> [ChangeLogEntry]
    func delete(entryID: UUID) async throws
    func deleteAll() async throws
}

public protocol TrackIDMapping: Sendable {
    func appleScriptID(forMusicKitID musicKitID: String) async -> String?
    func trackWithAppleScriptMetadata(for musicKitTrack: Track) async -> Track?
    func hasMappingFor(musicKitID: String) async -> Bool
}

public protocol AnalyticsService: Sendable {
    /// Records one privacy-safe operation result.
    func record(_ operation: AnalyticsOperation, duration: Duration, outcome: AnalyticsOutcome) async
}

extension AnalyticsService {
    /// Measures an async operation while preserving its value and error behavior.
    public func measure<Value: Sendable>(
        _ operation: AnalyticsOperation,
        isolation _: isolated (any Actor)? = #isolation,
        errorOutcome: @Sendable (any Error, Bool) -> AnalyticsOutcome = {
            AnalyticsOutcome(error: $0, isTaskCancelled: $1)
        },
        body: () async throws -> Value
    ) async rethrows -> Value {
        let clock = ContinuousClock()
        let start = clock.now

        do {
            let value = try await body()
            await record(operation, duration: start.duration(to: clock.now), outcome: .succeeded)
            return value
        } catch {
            await record(
                operation,
                duration: start.duration(to: clock.now),
                outcome: errorOutcome(error, Task.isCancelled)
            )
            throw error
        }
    }
}
