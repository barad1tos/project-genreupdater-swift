import Foundation
import Testing
@testable import Core
@testable import Services

// MARK: - Thread-Safe Accumulator

actor ProgressAccumulator {
    var items: [ProgressUpdate] = []

    func append(_ item: ProgressUpdate) {
        items.append(item)
    }

    func getAll() -> [ProgressUpdate] {
        items
    }
}

// MARK: - Helpers

func makeEditableTrack(
    id: String = "T1",
    name: String = "Come Together",
    artist: String = "Beatles",
    album: String = "Abbey Road",
    genre: String? = "Rock",
    year: Int? = 1969,
    dateAdded: Date? = nil
) -> Track {
    Track(
        id: id,
        name: name,
        artist: artist,
        album: album,
        genre: genre,
        year: year,
        dateAdded: dateAdded,
        trackStatus: nil // nil trackStatus = available
    )
}

// MARK: - Tests

struct CoordinatorFixture {
    let coordinator: UpdateCoordinator
    let bridge: MockAppleScriptClient
    let undo: UndoCoordinator
}

@Suite("UpdateCoordinator — single and multi-track updates")
struct UpdateCoordinatorTests {
    func makeCoordinator(
        year: Int? = nil,
        confidence: Int = 0,
        scriptBridge: MockAppleScriptClient? = nil,
        cache: MockCacheService? = nil,
        runtimeConfiguration: UpdateRuntimeConfiguration = UpdateRuntimeConfiguration(),
        yearDeterminator: YearDeterminator = YearDeterminator()
    ) async -> CoordinatorFixture {
        let bridge = scriptBridge ?? MockAppleScriptClient()
        let store = MockTrackStore()
        let cacheService = cache ?? MockCacheService()
        let undoDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateCoordinatorTests-\(UUID().uuidString)")
        let undo = UndoCoordinator(scriptBridge: bridge, directory: undoDir)

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
            yearDeterminator: yearDeterminator,
            runtimeConfiguration: runtimeConfiguration
        )

        return CoordinatorFixture(
            coordinator: coordinator,
            bridge: bridge,
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

    @Test("Genre mappings apply during workflow updates")
    func genreMappingsApplyDuringWorkflowUpdates() async throws {
        let runtimeConfiguration = UpdateRuntimeConfiguration(
            genreMappings: ["Electronica": "Electronic"]
        )
        let fixture = await makeCoordinator(runtimeConfiguration: runtimeConfiguration)

        let track = makeEditableTrack(genre: nil)
        let sourceDate = Date(timeIntervalSince1970: 1_234_567_890)
        let albumTracks = [
            makeEditableTrack(id: "T1", genre: "Electronica", dateAdded: sourceDate),
            makeEditableTrack(id: "T2", genre: "Electronica", dateAdded: sourceDate.addingTimeInterval(60)),
        ]

        let changes = try await fixture.coordinator.updateTrack(
            track,
            albumTracks: albumTracks,
            options: UpdateOptions(updateGenre: true, updateYear: false),
            dryRun: true
        )

        let genreChange = changes.first { $0.changeType == .genreUpdate }
        #expect(genreChange?.newValue == "Electronic")
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

    @Test("Local album year determination runs before API lookup")
    func localAlbumYearDeterminationRunsBeforeAPILookup() async throws {
        let fixture = await makeCoordinator(year: 2020, confidence: 90)

        let track = makeEditableTrack(year: 1969)
        let albumTracks = [
            makeEditableTrack(id: "T1", year: 1970),
            makeEditableTrack(id: "T2", year: 1970),
            makeEditableTrack(id: "T3", year: 1970),
        ]

        let changes = try await fixture.coordinator.updateTrack(
            track,
            albumTracks: albumTracks,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        let yearChange = changes.first { $0.changeType == .yearUpdate }
        #expect(yearChange?.newValue == "1970")
        #expect(yearChange?.source == "Dominant")
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

        // Wait for unstructured Task closures to deliver all progress updates
        for _ in 0 ..< 20 {
            let current = await accumulator.getAll()
            if current.count >= 4 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let updates = await accumulator.getAll()
        // 3 tracks + 1 complete
        #expect(updates.count == 4)
        #expect(updates.contains { $0.phase == .complete })
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

extension UpdateCoordinatorTests {
    static func ignoreProgress(_: ProgressUpdate) {
        // This test asserts returned entries only; progress emission is covered separately.
    }

    @Test("Multi-track update returns only entries created by the current call")
    func multiTrackUpdateReturnsOnlyCurrentEntries() async throws {
        let fixture = await makeCoordinator(year: 2020, confidence: 90)
        await fixture.undo.recordChange(ChangeLogEntry(
            changeType: .genreUpdate,
            trackID: "previous",
            artist: "Previous Artist"
        ))

        let result = try await fixture.coordinator.updateTracks(
            [makeEditableTrack(id: "current", year: 1969)],
            options: UpdateOptions(updateGenre: false, updateYear: true),
            progressHandler: Self.ignoreProgress
        )

        #expect(result.entries.map(\.trackID) == ["current"])
        #expect(!result.entries.contains { $0.trackID == "previous" })
        #expect(result.failedTrackIDs.isEmpty)
    }
}
