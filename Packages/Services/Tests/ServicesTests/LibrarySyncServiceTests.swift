import Foundation
import Testing
@testable import Core
@testable import Services

// MARK: - Configurable Music.app Observer

actor SyncMockScriptClient: MusicAppReading {
    var libraryTrackIDs: [String] = []
    var tracksByID: [String: Track] = [:]
    private let observedAt: @Sendable () -> Date
    private var fetchAllTrackIDsError: AppleScriptBridgeError?
    private var observationRequests: [LibraryObservationRequest] = []
    private var trackQueue: [[String: Track]] = []

    init(observedAt: @escaping @Sendable () -> Date = { .distantPast }) {
        self.observedAt = observedAt
    }

    func observe(_ request: LibraryObservationRequest) async throws -> LibraryObservation {
        observationRequests.append(request)
        if let fetchAllTrackIDsError {
            throw fetchAllTrackIDsError
        }
        let generation = try Self.generation()
        let allIDs = try libraryTrackIDs
            .map { rawValue -> MusicDatabaseTrackID in
                guard let databaseID = MusicDatabaseTrackID(rawValue: rawValue) else {
                    throw AppleScriptBridgeError.parseError(scriptName: "sync-mock", detail: "Invalid database ID")
                }
                return databaseID
            }
            .sorted { $0.rawValue < $1.rawValue }
        let observedTracks = trackQueue.isEmpty ? tracksByID : trackQueue.removeFirst()
        let requestedIdentityIDs = request.identityLookupIDs(in: allIDs)
        let identityRows = requestedIdentityIDs.compactMap { databaseID -> LibraryIdentityRow? in
            guard let track = observedTracks[databaseID.rawValue] else { return nil }
            return Self.identityRow(track, databaseID: databaseID)
        }
        let identitiesByID = Dictionary(uniqueKeysWithValues: identityRows.map { ($0.databaseID, $0) })
        let censusIDs = Set(allIDs)
        let currentIDs = request.inventory.admittedIDs(
            censusIDs: censusIDs,
            observed: identitiesByID,
            scope: request.scope
        )
        let requestedMetadataIDs = request.metadataLookupIDs(in: allIDs, admittedIDs: currentIDs)
        let rows = requestedMetadataIDs.compactMap { databaseID -> LibraryTrackRow? in
            guard let track = observedTracks[databaseID.rawValue] else { return nil }
            return Self.observationRow(track, databaseID: databaseID)
        }
        let derivedIdentities = request.scope.source == .fullLibrary ? rows.map(\.identityRow) : identityRows
        let identityRequestedIDs = request.reportedIdentityIDs(
            identityLookupIDs: requestedIdentityIDs,
            metadataLookupIDs: requestedMetadataIDs
        )
        let observedMetadataIDs = Set(rows.map(\.databaseID))
        let coverage = Self.makeCoverage(
            request: request,
            identities: derivedIdentities,
            identityRequestedIDs: identityRequestedIDs,
            metadataRequestedIDs: Set(requestedMetadataIDs),
            metadataObservedIDs: observedMetadataIDs
        )
        return LibraryObservation(
            tracks: rows,
            identities: derivedIdentities,
            epoch: LibraryObservationEpoch(
                censusIDs: censusIDs,
                currentIDs: currentIDs,
                scope: request.scope,
                observedAt: observedAt(),
                generation: generation
            ),
            coverage: coverage
        )
    }

    func recordedObservationRequests() -> [LibraryObservationRequest] {
        observationRequests
    }

    private static func generation() throws -> LibraryGeneration {
        guard let generation = LibraryGeneration(sourceValue: "sync-mock") else {
            throw AppleScriptBridgeError.parseError(scriptName: "sync-mock", detail: "Missing generation")
        }
        return generation
    }

    private static func makeCoverage(
        request: LibraryObservationRequest,
        identities: [LibraryIdentityRow],
        identityRequestedIDs: Set<MusicDatabaseTrackID>,
        metadataRequestedIDs: Set<MusicDatabaseTrackID>,
        metadataObservedIDs: Set<MusicDatabaseTrackID>
    ) -> LibraryObservationCoverage {
        let identityObservedIDs = Set(identities.map(\.databaseID))
        let missingIdentityIDs = identityRequestedIDs.subtracting(identityObservedIDs)
        return LibraryObservationCoverage(
            membership: request.scope.source == .fullLibrary
                ? .full
                : .scoped(unobservedIDs: missingIdentityIDs),
            identity: IdentityCompleteness(
                requestedIDs: identityRequestedIDs,
                observedIDs: identityObservedIDs
            ),
            metadata: MetadataCompleteness(
                requestedIDs: metadataRequestedIDs,
                observedIDs: metadataObservedIDs
            ),
            issues: []
        )
    }

    private static func identityRow(
        _ track: Track,
        databaseID: MusicDatabaseTrackID
    ) -> LibraryIdentityRow {
        LibraryIdentityRow(
            databaseID: databaseID,
            artist: .value(track.artist),
            albumArtist: track.albumArtist.map(Observed.value) ?? .absent
        )
    }

    private static func observationRow(
        _ track: Track,
        databaseID: MusicDatabaseTrackID
    ) -> LibraryTrackRow {
        LibraryTrackRow(
            databaseID: databaseID,
            metadata: LibraryTrackMetadata(
                text: LibraryTrackText(
                    name: .value(track.name),
                    artist: .value(track.artist),
                    album: .value(track.album),
                    albumArtist: track.albumArtist.map(Observed.value) ?? .absent
                ),
                genre: track.genre.map(Observed.value) ?? .absent,
                editableYear: track.year.map(Observed.value) ?? .absent,
                releaseYear: track.releaseYear.map(Observed.value) ?? .absent,
                dateAdded: track.dateAdded.map(Observed.value) ?? .absent,
                lastModified: track.lastModified.map(Observed.value) ?? .absent,
                status: track.trackStatus.map(Observed.value) ?? .absent
            )
        )
    }
}

// MARK: - Configurable Mock Track Store

actor SyncMockTrackStore: TrackStateStore {
    var storedTracks: [Track] = []
    private var presentIDs: Set<MusicDatabaseTrackID> = []
    private var certificates: [ScopeCertificate] = []
    private var revision = MirrorRevision.initial
    private var conflictsRemaining = 0

    func initialize() async throws {}

    func loadMirrorSnapshot() async throws -> TrackMirrorSnapshot {
        try mirrorSnapshot(
            revision: revision,
            tracks: storedTracks,
            presentIDs: presentIDs,
            certificates: certificates
        )
    }

    @discardableResult
    func commitMirror(_ update: MirrorCommit) async throws -> MirrorCommitResult {
        if conflictsRemaining > 0 {
            let nextRevision = try revision.advanced()
            conflictsRemaining -= 1
            revision = nextRevision
            throw MirrorRevisionConflict(expected: update.baseRevision, actual: revision)
        }
        guard update.baseRevision == revision else {
            throw MirrorRevisionConflict(expected: update.baseRevision, actual: revision)
        }
        let nextRevision = try revision.advanced()
        switch update.certificates {
        case .preserve:
            break
        case .invalidate:
            certificates = []
        case let .replace(certificate), let .rebase(certificate):
            certificates = [certificate]
        }
        if let membershipIDs = inventoryIDs(update.inventoryChange) {
            presentIDs = Set(membershipIDs)
        }
        applyInventory(update.inventoryChange, to: &storedTracks)
        for track in update.upserts {
            if let index = storedTracks.firstIndex(where: { $0.id == track.id }) {
                storedTracks[index] = track
            } else {
                storedTracks.append(track)
            }
        }
        revision = nextRevision
        return try MirrorCommitResult(
            revision: revision,
            snapshot: mirrorSnapshot(
                revision: revision,
                tracks: storedTracks,
                presentIDs: presentIDs,
                certificates: certificates
            )
        )
    }

    func getTrack(byID id: String) async throws -> Track? {
        storedTracks.first { $0.id == id }
    }

    func persistAppliedChange(_ change: ChangeLogEntry) async throws {
        guard let index = storedTracks.firstIndex(where: { $0.id == change.trackID }) else { return }
        storedTracks[index] = try storedTracks[index].applying(change)
    }

    func getUnprocessedTracks() async throws -> [Track] {
        storedTracks
    }

    func trackCount() async throws -> Int {
        storedTracks.count
    }
}

// MARK: - Mock Helpers

extension SyncMockScriptClient {
    func setLibrary(ids: [String], tracks: [String: Track]) {
        libraryTrackIDs = ids
        tracksByID = tracks
    }

    func setFetchAllTrackIDsError(_ error: AppleScriptBridgeError) {
        fetchAllTrackIDsError = error
    }

    func queueObservationTracks(_ tracks: [[String: Track]]) {
        trackQueue = tracks
    }
}

extension SyncMockTrackStore {
    func setInventory(_ tracks: [Track]) {
        storedTracks = tracks.map { track in
            var canonical = track
            if canonical.appleScriptID == nil {
                canonical.appleScriptID = canonical.id
            }
            return canonical
        }
        presentIDs = Set(storedTracks.compactMap(\.databaseID))
        certificates = []
    }

    func setStored(_ tracks: [Track], certificateDate: Date = Date()) {
        setInventory(tracks)
        setScopeCertificate(testArtists: [], observedAt: certificateDate)
    }

    func setScopeCertificate(testArtists: [String], observedAt: Date = Date()) {
        do {
            let inventory = try replacementInventory(for: storedTracks)
            certificates = try [scopeCertificate(
                revision: revision,
                inventoryChange: inventory,
                testArtists: testArtists,
                trackIDs: storedTracks.compactMap(\.databaseID),
                observedAt: observedAt
            )]
        } catch {
            preconditionFailure("Invalid sync mock certificate: \(error.localizedDescription)")
        }
    }

    func readiness(testArtists: [String]) throws -> MirrorReadiness {
        try mirrorSnapshot(
            revision: revision,
            tracks: storedTracks,
            presentIDs: presentIDs,
            certificates: certificates
        )
        .readiness(for: MirrorRequirement(
            testArtists: testArtists,
            fieldSet: .processingV1,
            maximumMetadataAge: nil
        ))
    }

    func rejectNextMirrorCommits(_ count: Int = 1) {
        conflictsRemaining = count
    }
}

actor SyncMockLibrarySnapshotService: LibrarySnapshotService {
    var isEnabled = true
    private var didClearSnapshot = false
    private var metadata: LibraryCacheMetadata?
    private var shouldFailMetadataUpdates = false

    func loadSnapshot() async throws -> [Track]? {
        nil
    }
    func saveSnapshot(_: [Track]) async throws -> String {
        "snapshot"
    }
    func clearSnapshot() async {
        didClearSnapshot = true
    }
    func isSnapshotValid() async -> Bool {
        true
    }
    func getSnapshotMetadata() async -> LibraryCacheMetadata? {
        metadata
    }
    func updateSnapshotMetadata(_ metadata: LibraryCacheMetadata) async throws {
        if shouldFailMetadataUpdates {
            throw SyncSnapshotError.metadataUpdateFailed
        }
        self.metadata = metadata
    }
    func getLibraryModificationDate() async throws -> Date {
        .distantPast
    }

    func wasCleared() -> Bool {
        didClearSnapshot
    }

    func setMetadata(_ metadata: LibraryCacheMetadata) {
        self.metadata = metadata
    }

    func failMetadataUpdates() {
        shouldFailMetadataUpdates = true
    }
}

private enum SyncSnapshotError: Error {
    case metadataUpdateFailed
}

final class SyncDateProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func now() -> Date {
        lock.withLock {
            date
        }
    }

    func set(_ date: Date) {
        lock.withLock {
            self.date = date
        }
    }
}

func seedSyncCaches(_ cache: MockCacheService, artist: String, album: String) async {
    await cache.storeAlbumYear(artist: artist, album: album, year: 1970, confidence: 85)
    await cache.setCachedAPIResult(CachedAPIResult(
        artist: artist,
        album: album,
        year: 1970,
        source: "musicbrainz",
        timestamp: Date(),
        ttl: nil
    ))
}

func expectSyncCachesInvalidated(_ cache: MockCacheService, artist: String, album: String) async {
    let albumYear = await cache.getAlbumYear(artist: artist, album: album)
    let apiResult = await cache.getCachedAPIResult(
        artist: artist,
        album: album,
        source: "musicbrainz"
    )
    #expect(albumYear == nil)
    #expect(apiResult == nil)
}

func expectSyncCachesPreserved(_ cache: MockCacheService, artist: String, album: String) async {
    let albumYear = await cache.getAlbumYear(artist: artist, album: album)
    let apiResult = await cache.getCachedAPIResult(
        artist: artist,
        album: album,
        source: "musicbrainz"
    )
    #expect(albumYear?.year == 1970)
    #expect(apiResult?.year == 1970)
}
