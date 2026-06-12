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

// MARK: - Helpers

private func makeEditableTrack(
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

private struct CoordinatorFixture {
    let coordinator: UpdateCoordinator
    let bridge: MockAppleScriptClient
    let undo: UndoCoordinator
}

@Suite("UpdateCoordinator — single and multi-track updates")
struct UpdateCoordinatorTests {
    private func makeCoordinator(
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

    @Test("Configured album type patterns skip year updates")
    func configuredAlbumTypePatternsSkipYearUpdates() async throws {
        var albumTypeDetection = AlbumTypeDetectionConfig()
        albumTypeDetection.specialPatterns = ["archive"]
        albumTypeDetection.compilationPatterns = []
        albumTypeDetection.reissuePatterns = []

        let runtimeConfiguration = UpdateRuntimeConfiguration(
            minimumYearUpdateConfidence: 30,
            albumTypeDetection: albumTypeDetection
        )
        let fixture = await makeCoordinator(
            year: 2024,
            confidence: 95,
            runtimeConfiguration: runtimeConfiguration
        )

        let track = makeEditableTrack(album: "Studio Archive", year: 1999)
        let changes = try await fixture.coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        #expect(changes.isEmpty)
    }

    @Test("Runtime album type configuration update applies to subsequent year updates")
    func runtimeAlbumTypeConfigurationUpdateAppliesToSubsequentYearUpdates() async throws {
        let fixture = await makeCoordinator(
            year: 2024,
            confidence: 95,
            runtimeConfiguration: UpdateRuntimeConfiguration(minimumYearUpdateConfidence: 30)
        )
        let track = makeEditableTrack(album: "Session Archive", year: 1999)

        let beforeUpdate = try await fixture.coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )
        #expect(beforeUpdate.first { $0.changeType == .yearUpdate }?.newValue == "2024")

        var albumTypeDetection = AlbumTypeDetectionConfig()
        albumTypeDetection.specialPatterns = ["archive"]
        albumTypeDetection.compilationPatterns = []
        albumTypeDetection.reissuePatterns = []
        await fixture.coordinator.updateRuntimeConfiguration(
            UpdateRuntimeConfiguration(
                minimumYearUpdateConfidence: 30,
                albumTypeDetection: albumTypeDetection
            ),
            yearDeterminator: YearDeterminator()
        )

        let afterUpdate = try await fixture.coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )
        #expect(afterUpdate.allSatisfy { $0.changeType != .yearUpdate })
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

    @Test("Configured year confidence skips weak cache entries")
    func configuredYearConfidenceSkipsWeakCacheEntries() async throws {
        let cache = MockCacheService()
        await cache.storeAlbumYear(artist: "Beatles", album: "Abbey Road", year: 1970, confidence: 70)

        let runtimeConfiguration = UpdateRuntimeConfiguration(
            minimumYearUpdateConfidence: 80
        )
        let fixture = await makeCoordinator(
            year: 2020,
            confidence: 90,
            cache: cache,
            runtimeConfiguration: runtimeConfiguration
        )

        let track = makeEditableTrack(year: 1969)
        let changes = try await fixture.coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        let yearChange = changes.first { $0.changeType == .yearUpdate }
        #expect(yearChange?.newValue == "2020")
        #expect(yearChange?.source == "Definitive")
    }

    @Test("Configured cache threshold skips weak API persistence")
    func configuredCacheThresholdSkipsWeakAPIPersistence() async throws {
        let cache = MockCacheService()
        let runtimeConfiguration = UpdateRuntimeConfiguration(
            minimumYearUpdateConfidence: 30,
            minimumConfidenceToCache: 95
        )
        let fixture = await makeCoordinator(
            year: 2020,
            confidence: 30,
            cache: cache,
            runtimeConfiguration: runtimeConfiguration
        )

        let track = makeEditableTrack(year: 1969)
        let changes = try await fixture.coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true, minConfidence: 0),
            dryRun: true
        )

        let yearChange = changes.first { $0.changeType == .yearUpdate }
        #expect(yearChange?.newValue == "2020")

        let cached = await cache.getAlbumYear(artist: "Beatles", album: "Abbey Road")
        #expect(cached == nil)
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
    @Test("Year lookup setting disables year changes")
    func yearLookupSettingDisablesYearChanges() async throws {
        let runtimeConfiguration = UpdateRuntimeConfiguration(
            isYearLookupEnabled: false,
            minimumYearUpdateConfidence: 30
        )
        let fixture = await makeCoordinator(
            year: 2020,
            confidence: 95,
            runtimeConfiguration: runtimeConfiguration
        )

        let track = makeEditableTrack(year: 1969)
        let changes = try await fixture.coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        #expect(changes.allSatisfy { $0.changeType != .yearUpdate })
    }

    @Test("Existing genres are preserved when override is disabled")
    func existingGenresArePreservedWhenOverrideIsDisabled() async throws {
        let fixture = await makeCoordinator()
        let sourceDate = Date(timeIntervalSince1970: 1_234_567_890)
        let track = makeEditableTrack(genre: "Rock")
        let albumTracks = [
            makeEditableTrack(id: "T1", genre: "Electronic", dateAdded: sourceDate),
            makeEditableTrack(id: "T2", genre: "Electronic", dateAdded: sourceDate.addingTimeInterval(60)),
        ]

        let changes = try await fixture.coordinator.updateTrack(
            track,
            albumTracks: albumTracks,
            options: UpdateOptions(updateGenre: true, updateYear: false),
            dryRun: true
        )

        #expect(changes.allSatisfy { $0.changeType != .genreUpdate })
    }

    @Test("Existing genres update when override is enabled")
    func existingGenresUpdateWhenOverrideIsEnabled() async throws {
        let runtimeConfiguration = UpdateRuntimeConfiguration(shouldOverrideExistingGenres: true)
        let fixture = await makeCoordinator(runtimeConfiguration: runtimeConfiguration)
        let sourceDate = Date(timeIntervalSince1970: 1_234_567_890)
        let track = makeEditableTrack(genre: "Rock")
        let albumTracks = [
            makeEditableTrack(id: "T1", genre: "Electronic", dateAdded: sourceDate),
            makeEditableTrack(id: "T2", genre: "Electronic", dateAdded: sourceDate.addingTimeInterval(60)),
        ]

        let changes = try await fixture.coordinator.updateTrack(
            track,
            albumTracks: albumTracks,
            options: UpdateOptions(updateGenre: true, updateYear: false),
            dryRun: true
        )

        let genreChange = changes.first { $0.changeType == .genreUpdate }
        #expect(genreChange?.oldValue == "Rock")
        #expect(genreChange?.newValue == "Electronic")
    }
}
