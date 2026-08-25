import Foundation
import Testing
@testable import Core
@testable import Services

// MARK: - Configurable Music.app Observer

actor SyncMockScriptClient: MusicAppReading {
    var libraryTrackIDs: [String] = []
    var tracksByID: [String: Track] = [:]
    private var fetchAllTrackIDsError: AppleScriptBridgeError?
    private var observationRequests: [LibraryObservationRequest] = []

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
        let previousIDs: Set<MusicDatabaseTrackID> = switch request.previous {
        case .initial:
            []
        case let .verified(mirror):
            Set(mirror.tracksByID.keys)
        }
        let requestedIDs = request.refresh == .force
            ? allIDs
            : allIDs.filter { !previousIDs.contains($0) }
        let rows = requestedIDs.compactMap { databaseID -> LibraryTrackRow? in
            guard let track = tracksByID[databaseID.rawValue] else { return nil }
            return Self.observationRow(track, databaseID: databaseID)
        }
        let scopedRows = rows.filter { row in
            guard request.scope.source == .testArtists else { return true }
            let artist = if case let .value(albumArtist) = row.albumArtist {
                albumArtist
            } else if case let .value(trackArtist) = row.artist {
                trackArtist
            } else {
                ""
            }
            return ArtistAllowList.containsNormalized(artist, in: request.scope.normalizedTestArtists)
        }
        let currentIDs: Set<MusicDatabaseTrackID> = if request.scope.source == .fullLibrary {
            Set(allIDs)
        } else {
            Set(scopedRows.map(\.databaseID))
        }
        let observedIDs = Set(rows.map(\.databaseID))
        let missingIDs = Set(requestedIDs).subtracting(observedIDs)
        return LibraryObservation(
            tracks: scopedRows,
            censusIDs: Set(allIDs),
            currentIDs: currentIDs,
            scope: request.scope,
            observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            membership: request.scope.source == .fullLibrary
                ? .full
                : .scoped(unobservedIDs: missingIDs),
            metadata: MetadataCompleteness(
                requestedIDs: Set(requestedIDs),
                observedIDs: observedIDs
            ),
            generation: generation,
            issues: []
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
    private var isSeeded = false

    func initialize() async throws {}

    func loadAllTracks() async throws -> [Track] {
        storedTracks
    }

    func loadMirrorSnapshot() async throws -> TrackMirrorSnapshot {
        TrackMirrorSnapshot(tracks: storedTracks, isSeeded: isSeeded || !storedTracks.isEmpty)
    }

    func applyMirror(_ update: TrackMirrorUpdate) async throws {
        isSeeded = true
        let deletionIDs = Set(update.deletions.map(\.rawValue))
        storedTracks.removeAll { deletionIDs.contains($0.id) }
        for track in update.upserts {
            if let index = storedTracks.firstIndex(where: { $0.id == track.id }) {
                storedTracks[index] = track
            } else {
                storedTracks.append(track)
            }
        }
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
}

extension SyncMockTrackStore {
    func setStored(_ tracks: [Track]) {
        isSeeded = true
        storedTracks = tracks.map { track in
            var canonical = track
            if canonical.appleScriptID == nil {
                canonical.appleScriptID = canonical.id
            }
            return canonical
        }
    }
}

actor SyncMockLibrarySnapshotService: LibrarySnapshotService {
    var isEnabled = true
    private var didClearSnapshot = false
    private var metadata: LibraryCacheMetadata?

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
