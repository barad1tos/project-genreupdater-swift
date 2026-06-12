import Foundation
@testable import Core
@testable import Services

// MARK: - MockAppleScriptClient

actor MockAppleScriptClient: AppleScriptClient {
    var writtenProperties: [(trackID: String, property: String, value: String)] = []
    var shouldThrow = false

    func initialize() async throws {}

    func runScript(
        name _: String,
        arguments _: [String],
        timeout _: Duration?
    ) async throws -> String? {
        nil
    }

    func fetchTracksByIDs(
        _ _: [String],
        batchSize _: Int,
        timeout _: Duration?
    ) async throws -> [Track] {
        []
    }

    func fetchAllTrackIDs(timeout _: Duration?) async throws -> [String] {
        []
    }

    func updateTrackProperty(trackID: String, property: String, value: String) async throws {
        if shouldThrow {
            throw MockScriptError.intentional
        }
        writtenProperties.append((trackID, property, value))
    }

    func setThrowMode(_ shouldFail: Bool) {
        shouldThrow = shouldFail
    }
}

// MARK: - MockScriptError

enum MockScriptError: Error {
    case intentional
}

// MARK: - MockTrackStore

actor MockTrackStore: TrackStateStore {
    var tracks: [Track] = []

    func initialize() async throws {}

    func loadAllTracks() async throws -> [Track] {
        tracks
    }

    func saveTracks(_ newTracks: [Track]) async throws {
        tracks = newTracks
    }

    func getTrack(byID id: String) async throws -> Track? {
        tracks.first { $0.id == id }
    }

    func updateTrackProcessingState(
        id _: String,
        genreUpdated _: Bool?,
        yearUpdated _: Bool?
    ) async throws {}

    func getUnprocessedTracks() async throws -> [Track] {
        tracks
    }

    func trackCount() async throws -> Int {
        tracks.count
    }
}

// MARK: - MockCacheService

actor MockCacheService: CacheService {
    var albumYears: [String: AlbumCacheEntry] = [:]
    var apiResults: [String: CachedAPIResult] = [:]

    func initialize() async throws {}
    func get<T: Codable & Sendable>(key _: String) async -> T? {
        nil
    }
    func set(key _: String, value _: some Codable & Sendable, ttl _: TimeInterval?) async {}
    func invalidate(key _: String) async {}
    func clear() async {}

    func getAlbumYear(artist: String, album: String) async -> AlbumCacheEntry? {
        albumYears["\(artist)-\(album)"]
    }

    func storeAlbumYear(artist: String, album: String, year: Int, confidence: Int) async {
        albumYears["\(artist)-\(album)"] = AlbumCacheEntry(
            artist: artist,
            album: album,
            year: year,
            confidence: confidence,
            timestamp: Date()
        )
    }

    func invalidateAlbum(artist _: String, album _: String) async {}
    func getCachedAPIResult(artist: String, album: String, source: String) async -> CachedAPIResult? {
        apiResults["\(artist)-\(album)-\(source)"]
    }
    func setCachedAPIResult(_ result: CachedAPIResult) async {
        apiResults["\(result.artist)-\(result.album)-\(result.source)"] = result
    }
    func syncToDisk() async throws {}
}

// MARK: - MockAPIService

/// Mock `ExternalAPIService` for testing orchestration logic.
///
/// Returns a preconfigured `YearResult`, optionally throwing or delaying
/// to simulate network failures and slow responses.
struct MockAPIService: ExternalAPIService {
    let yearResult: YearResult
    let shouldThrow: Bool
    let delay: Duration

    init(
        yearResult: YearResult = YearResult(),
        shouldThrow: Bool = false,
        delay: Duration = .zero
    ) {
        self.yearResult = yearResult
        self.shouldThrow = shouldThrow
        self.delay = delay
    }

    func getAlbumYear(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        if shouldThrow {
            throw MockAPIError.intentional
        }
        return yearResult
    }

    func getArtistActivityPeriod(
        normalizedArtist _: String
    ) async throws -> (start: Int?, end: Int?) {
        (nil, nil)
    }

    func getArtistStartYear(
        normalizedArtist _: String
    ) async throws -> Int? {
        nil
    }

    func initialize(force _: Bool) async throws {}
    func close() async {}
}

// MARK: - MockAPIError

enum MockAPIError: Error {
    case intentional
}
