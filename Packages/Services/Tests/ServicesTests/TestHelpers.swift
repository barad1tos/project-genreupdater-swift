import Foundation
@testable import Core
@testable import Services

// MARK: - APIOrchestrator Test Factory

func makeAPIOrchestrator(
    musicBrainz: any ExternalAPIService,
    discogs: any ExternalAPIService,
    appleMusic: any ExternalAPIService,
    cache: (any CacheService)? = nil,
    disabledSources: Set<APISource> = [],
    configure: (inout APIOrchestratorConfiguration) -> Void = { _ in
        // Default test configuration needs no customization.
    }
) -> APIOrchestrator {
    var configuration = APIOrchestratorConfiguration()
    configuration.cache = cache
    configuration.disabledSources = disabledSources
    configure(&configuration)
    return APIOrchestrator(
        services: APIOrchestratorServices(
            musicBrainz: musicBrainz,
            discogs: discogs,
            appleMusic: appleMusic
        ),
        configuration: configuration
    )
}

// MARK: - MockAppleScriptClient

actor MockAppleScriptClient: AppleScriptClient {
    var writtenProperties: [(trackID: String, property: String, value: String)] = []
    var trackIDsToFetch: [String] = []
    var tracksByID: [String: Track] = [:]
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
        _ trackIDs: [String],
        batchSize _: Int,
        timeout _: Duration?
    ) async throws -> [Track] {
        trackIDs.compactMap { tracksByID[$0] }
    }

    func fetchAllTrackIDs(timeout _: Duration?) async throws -> [String] {
        trackIDsToFetch
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

    func setFetchedTracks(_ tracks: [Track]) {
        trackIDsToFetch = tracks.map(\.id)
        tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
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

    func deleteTrackIDs(_ ids: [String]) async throws -> Int {
        let idsToDelete = Set(ids)
        let originalCount = tracks.count
        tracks.removeAll { idsToDelete.contains($0.id) }
        return originalCount - tracks.count
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
    private var genericEntries: [String: MockGenericCacheEntry] = [:]

    func initialize() async throws {}
    func get<T: Codable & Sendable>(key: String) async -> T? {
        guard let entry = genericEntries[key], !entry.isExpired else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: entry.data)
    }

    func set(key: String, value: some Codable & Sendable, ttl: TimeInterval?) async {
        guard let data = try? JSONEncoder().encode(value) else { return }
        genericEntries[key] = MockGenericCacheEntry(data: data, timestamp: .now, ttl: ttl)
    }
    func invalidate(key: String) async {
        genericEntries.removeValue(forKey: key)
    }

    func clear() async {
        genericEntries.removeAll()
        albumYears.removeAll()
        apiResults.removeAll()
    }

    func getAlbumYear(artist: String, album: String) async -> AlbumCacheEntry? {
        albumYears[albumYearKey(artist: artist, album: album)]
    }

    func storeAlbumYear(artist: String, album: String, year: Int, confidence: Int) async {
        albumYears[albumYearKey(artist: artist, album: album)] = AlbumCacheEntry(
            artist: artist,
            album: album,
            year: year,
            confidence: confidence,
            timestamp: Date()
        )
    }

    func invalidateAlbum(artist: String, album: String) async {
        albumYears.removeValue(forKey: albumYearKey(artist: artist, album: album))
    }

    func getCachedAPIResult(artist: String, album: String, source: String) async -> CachedAPIResult? {
        apiResults[apiResultKey(artist: artist, album: album, source: source)]
    }

    func setCachedAPIResult(_ result: CachedAPIResult) async {
        apiResults[apiResultKey(artist: result.artist, album: result.album, source: result.source)] = result
    }

    func syncToDisk() async throws {}

    private func albumYearKey(artist: String, album: String) -> String {
        "\(normalizeForMatching(artist))-\(normalizeForMatching(album))"
    }

    private func apiResultKey(artist: String, album: String, source: String) -> String {
        "\(normalizeForMatching(artist))-\(normalizeForMatching(album))-\(normalizeForMatching(source))"
    }
}

private struct MockGenericCacheEntry {
    let data: Data
    let timestamp: Date
    let ttl: TimeInterval?

    var isExpired: Bool {
        guard let ttl else { return false }
        return Date.now > timestamp.addingTimeInterval(ttl)
    }
}

// MARK: - MockAPIService

/// Mock `ExternalAPIService` for testing orchestration logic.
///
/// Returns a preconfigured `YearResult`, optionally throwing or delaying
/// to simulate network failures and slow responses.
struct MockAPIService: ExternalAPIService {
    let yearResult: YearResult
    let releaseCandidates: [ReleaseCandidate]
    let shouldThrow: Bool
    let delay: Duration
    let artistActivityPeriod: (start: Int?, end: Int?)
    let artistStartYear: Int?

    init(
        yearResult: YearResult = YearResult(),
        releaseCandidates: [ReleaseCandidate] = [],
        shouldThrow: Bool = false,
        delay: Duration = .zero,
        artistActivityPeriod: (start: Int?, end: Int?) = (nil, nil),
        artistStartYear: Int? = nil
    ) {
        self.yearResult = yearResult
        self.releaseCandidates = releaseCandidates
        self.shouldThrow = shouldThrow
        self.delay = delay
        self.artistActivityPeriod = artistActivityPeriod
        self.artistStartYear = artistStartYear
    }

    func getAlbumYear(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        try await waitIfNeeded()
        if shouldThrow {
            throw MockAPIError.intentional
        }
        return yearResult
    }

    func getReleaseCandidates(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> [ReleaseCandidate] {
        try await waitIfNeeded()
        if shouldThrow {
            throw MockAPIError.intentional
        }
        return releaseCandidates
    }

    func getArtistActivityPeriod(
        normalizedArtist _: String
    ) async throws -> (start: Int?, end: Int?) {
        if shouldThrow {
            throw MockAPIError.intentional
        }
        return artistActivityPeriod
    }

    func getArtistStartYear(
        normalizedArtist _: String
    ) async throws -> Int? {
        if shouldThrow {
            throw MockAPIError.intentional
        }
        return artistStartYear
    }

    func initialize(force _: Bool) async throws {}
    func close() async {}

    private func waitIfNeeded() async throws {
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
    }
}

// MARK: - MockAPIError

enum MockAPIError: Error {
    case intentional
}
