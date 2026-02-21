import Foundation
import Testing
@testable import Core
@testable import Services

// MARK: - Thread-Safe Accumulator

private actor ProgressAccumulator {
    var items: [ProgressUpdate] = []

    func append(_ item: ProgressUpdate) {
        items.append(item)
    }

    func getAll() -> [ProgressUpdate] {
        items
    }
}

// MARK: - Mock Cache Service

actor MockCacheService: CacheService {
    var albumYears: [String: AlbumCacheEntry] = [:]

    func initialize() async throws {}
    func get<T: Codable & Sendable>(key: String) async -> T? {
        nil
    }
    func set(key: String, value: some Codable & Sendable, ttl: TimeInterval?) async {}
    func invalidate(key: String) async {}
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

    func invalidateAlbum(artist: String, album: String) async {}
    func getCachedAPIResult(artist: String, album: String, source: String) async -> CachedAPIResult? {
        nil
    }
    func setCachedAPIResult(_ result: CachedAPIResult) async {}
    func syncToDisk() async throws {}
}

// MARK: - Helpers

private func makeEditableTrack(
    id: String = "T1",
    artist: String = "Beatles",
    album: String = "Abbey Road",
    genre: String? = "Rock",
    year: Int? = 1969
) -> Track {
    Track(
        id: id,
        name: "Come Together",
        artist: artist,
        album: album,
        genre: genre,
        year: year,
        trackStatus: nil // nil trackStatus = available
    )
}

// MARK: - Tests

private struct CoordinatorFixture {
    let coordinator: UpdateCoordinator
    let bridge: MockAppleScriptClient
    let store: MockTrackStore
    let cache: MockCacheService
    let undo: UndoCoordinator
}

@Suite("UpdateCoordinator — single and multi-track updates")
struct UpdateCoordinatorTests {
    private func makeCoordinator(
        year: Int? = nil,
        confidence: Int = 0,
        scriptBridge: MockAppleScriptClient? = nil,
        cache: MockCacheService? = nil
    ) async -> CoordinatorFixture {
        let bridge = scriptBridge ?? MockAppleScriptClient()
        let store = MockTrackStore()
        let cacheService = cache ?? MockCacheService()
        let undo = UndoCoordinator(scriptBridge: bridge)

        // yearScores must be populated for APIOrchestrator.aggregateResults
        let yearScores: [Int: Int] = if let year {
            [year: confidence]
        } else {
            [:]
        }
        let yearResult = YearResult(
            year: year,
            confidence: confidence,
            yearScores: yearScores
        )
        let apiService = MockAPIService(yearResult: yearResult)
        let orchestrator = APIOrchestrator(
            musicBrainz: apiService,
            discogs: apiService,
            appleMusic: apiService
        )

        let coordinator = UpdateCoordinator(
            apiOrchestrator: orchestrator,
            scriptBridge: bridge,
            trackStore: store,
            cache: cacheService,
            undoCoordinator: undo,
            genreDeterminator: GenreDeterminator(),
            yearDeterminator: YearDeterminator()
        )

        return CoordinatorFixture(
            coordinator: coordinator,
            bridge: bridge,
            store: store,
            cache: cacheService,
            undo: undo
        )
    }

    @Test("Dry-run returns changes without writing")
    func dryRunNoWrite() async throws {
        let fixture = await makeCoordinator(year: 2020, confidence: 90)

        let track = makeEditableTrack(year: 1969)
        let changes = try await fixture.coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        #expect(!changes.isEmpty)
        let written = await fixture.bridge.writtenProperties
        #expect(written.isEmpty)
    }

    @Test("Write mode applies changes to Music.app")
    func writeAppliesChanges() async throws {
        let fixture = await makeCoordinator(year: 2020, confidence: 90)

        let track = makeEditableTrack(year: 1969)
        let changes = try await fixture.coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: false
        )

        #expect(!changes.isEmpty)
        let written = await fixture.bridge.writtenProperties
        #expect(written.contains { $0.property == "year" && $0.value == "2020" })
    }

    @Test("Non-editable track throws trackNotEditable")
    func nonEditableTrackThrows() async {
        let fixture = await makeCoordinator()

        let track = Track(
            id: "T1",
            name: "Track",
            artist: "Artist",
            album: "Album",
            trackStatus: "prerelease"
        )

        await #expect(throws: UpdateCoordinatorError.self) {
            try await fixture.coordinator.updateTrack(
                track,
                options: UpdateOptions(),
                dryRun: true
            )
        }
    }

    @Test("Cache hit skips API call")
    func cacheHitSkipsAPI() async throws {
        let cache = MockCacheService()
        await cache.storeAlbumYear(artist: "Beatles", album: "Abbey Road", year: 1970, confidence: 85)

        let fixture = await makeCoordinator(
            cache: cache
        )

        let track = makeEditableTrack(year: 1969)
        let changes = try await fixture.coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        let yearChange = changes.first { $0.changeType == .yearUpdate }
        #expect(yearChange != nil)
        #expect(yearChange?.newValue == "1970")
        #expect(yearChange?.source == "Cache")
    }

    @Test("Changes recorded in undo coordinator after write")
    func changesRecordedInUndo() async throws {
        let fixture = await makeCoordinator(year: 2020, confidence: 90)

        let track = makeEditableTrack(year: 1969)
        _ = try await fixture.coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: false
        )

        let history = await fixture.undo.getHistory()
        #expect(!history.isEmpty)
        #expect(history.first?.changeType == .yearUpdate)
    }

    @Test("Multi-track update reports progress")
    func multiTrackProgress() async throws {
        let fixture = await makeCoordinator(year: 2020, confidence: 90)

        let tracks = (0 ..< 3).map { i in
            makeEditableTrack(id: "T\(i)", year: 1969)
        }

        let accumulator = ProgressAccumulator()
        let result = try await fixture.coordinator.updateTracks(
            tracks,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            progressHandler: { update in
                Task { await accumulator.append(update) }
            }
        )

        try await Task.sleep(for: .milliseconds(50))
        let updates = await accumulator.getAll()
        // 3 tracks + 1 complete
        #expect(updates.count == 4)
        #expect(updates.last?.phase == .complete)
        #expect(result.entries.count == 3)
        #expect(result.failedTrackIDs.isEmpty)
    }

    @Test("Same year as current produces no change")
    func sameYearNoChange() async throws {
        let fixture = await makeCoordinator(year: 1969, confidence: 90)

        let track = makeEditableTrack(year: 1969)
        let changes = try await fixture.coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        #expect(changes.isEmpty)
    }
}
