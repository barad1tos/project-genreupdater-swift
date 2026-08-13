import Foundation
import Testing
@testable import Core
@testable import Services

// MARK: - Configurable Mock Script Client

struct SyncFetchRequest {
    let trackIDs: [String]
    let batchSize: Int
    let timeout: Duration?
}

actor SyncMockScriptClient: AppleScriptClient {
    var libraryTrackIDs: [String] = []
    var tracksByID: [String: Track] = [:]
    private var tracksByArtist: [String: [Track]] = [:]
    private var fetchAllTrackIDsError: AppleScriptBridgeError?
    private var fetchTracksRequests: [SyncFetchRequest] = []
    private var fetchAllTrackIDsTimeouts: [Duration?] = []
    private var fetchTracksArtistRequests: [(artist: String?, timeout: Duration?)] = []

    func initialize() async throws {}

    func runScript(
        name: String,
        arguments: [String],
        timeout: Duration?
    ) async throws -> String? {
        guard name == "fetch_tracks" else { return nil }

        let artist = arguments.first
        fetchTracksArtistRequests.append((artist: artist, timeout: timeout))
        let tracks = artist.flatMap { tracksByArtist[$0] } ?? Array(tracksByID.values)
        guard !tracks.isEmpty else { return "NO_TRACKS_FOUND" }
        return tracks.map(Self.appleScriptRecord).joined(separator: String(Track.recordSeparator))
    }

    func fetchTracksByIDs(
        _ trackIDs: [String],
        batchSize: Int,
        timeout: Duration?
    ) async throws -> [Track] {
        fetchTracksRequests.append(SyncFetchRequest(
            trackIDs: trackIDs,
            batchSize: batchSize,
            timeout: timeout
        ))
        return trackIDs.compactMap { tracksByID[$0] }
    }

    func fetchAllTrackIDs(timeout: Duration?) async throws -> [String] {
        fetchAllTrackIDsTimeouts.append(timeout)
        if let fetchAllTrackIDsError {
            throw fetchAllTrackIDsError
        }
        return libraryTrackIDs
    }

    func updateTrackProperty(
        trackID _: String,
        property _: String,
        value _: String
    ) async throws -> AppleScriptWriteResult {
        try Task.checkCancellation()
        return .changed
    }

    func batchUpdateTracks(_: [TrackPropertyUpdate]) async throws {
        try Task.checkCancellation()
    }

    func lastFetchTracksRequest() -> (batchSize: Int, timeout: Duration?)? {
        guard let request = fetchTracksRequests.last else { return nil }
        return (batchSize: request.batchSize, timeout: request.timeout)
    }

    func fetchTracksRequestCount() -> Int {
        fetchTracksRequests.count
    }

    func fetchedTrackIDSets() -> [Set<String>] {
        fetchTracksRequests.map { Set($0.trackIDs) }
    }

    func lastFetchAllTrackIDsTimeout() -> Duration? {
        guard let timeout = fetchAllTrackIDsTimeouts.last else { return nil }
        return timeout
    }

    func fetchAllTrackIDsCallCount() -> Int {
        fetchAllTrackIDsTimeouts.count
    }

    func fetchedArtists() -> [String?] {
        fetchTracksArtistRequests.map(\.artist)
    }

    func setArtistTracks(_ tracks: [Track], for artist: String) {
        tracksByArtist[artist] = tracks
    }

    private static func appleScriptRecord(_ track: Track) -> String {
        [
            track.appleScriptID ?? track.id,
            track.name,
            track.artist,
            track.albumArtist ?? "",
            track.album,
            track.genre ?? "",
            "",
            "",
            track.trackStatus ?? "",
            track.year.map(String.init) ?? "",
            track.releaseYear.map(String.init) ?? "",
            ""
        ].joined(separator: String(Track.fieldSeparator))
    }
}

// MARK: - Configurable Mock Track Store

actor SyncMockTrackStore: TrackStateStore {
    var storedTracks: [Track] = []

    func initialize() async throws {}

    func loadAllTracks() async throws -> [Track] {
        storedTracks
    }

    func saveTracks(_ tracks: [Track]) async throws {
        for track in tracks {
            if let index = storedTracks.firstIndex(where: { $0.id == track.id }) {
                storedTracks[index] = track
            } else {
                storedTracks.append(track)
            }
        }
    }

    func deleteTrackIDs(_ ids: [String]) async throws -> Int {
        let idsToDelete = Set(ids)
        let originalCount = storedTracks.count
        storedTracks.removeAll { idsToDelete.contains($0.id) }
        return originalCount - storedTracks.count
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

actor SyncMockReadProvider: LibraryReadProvider {
    var snapshot = LibraryReadSnapshot(
        tracks: [],
        scannedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    private(set) var requests: [LibraryReadRequest] = []

    func loadLibrarySnapshot(request: LibraryReadRequest) async throws -> LibraryReadSnapshot {
        requests.append(request)
        return snapshot
    }

    func setTracks(_ tracks: [Track]) {
        snapshot = LibraryReadSnapshot(
            tracks: tracks,
            scannedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    func requestCount() -> Int {
        requests.count
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
        storedTracks = tracks
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
