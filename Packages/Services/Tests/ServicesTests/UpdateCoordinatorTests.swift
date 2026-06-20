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

actor MockLibrarySnapshotService: LibrarySnapshotService {
    var isEnabled = true
    var isDeltaEnabled = true
    private var didClearSnapshot = false

    func loadSnapshot() async throws -> [Track]? {
        nil
    }
    func saveSnapshot(_: [Track]) async throws -> String {
        "snapshot"
    }
    func isSnapshotValid() async -> Bool {
        true
    }
    func getSnapshotMetadata() async -> LibraryCacheMetadata? {
        nil
    }
    func updateSnapshotMetadata(_: LibraryCacheMetadata) async throws {}
    func loadDelta() async -> LibraryDeltaCache? {
        nil
    }
    func saveDelta(_: LibraryDeltaCache) async throws {}
    func getLibraryModificationDate() async throws -> Date {
        .distantPast
    }

    func clearSnapshot() async {
        didClearSnapshot = true
    }

    func wasCleared() -> Bool {
        didClearSnapshot
    }
}

@Suite("UpdateCoordinator — single and multi-track updates")
struct UpdateCoordinatorTests {
    func makeCoordinator(
        year: Int? = nil,
        confidence: Int = 0,
        scriptBridge: MockAppleScriptClient? = nil,
        cache: MockCacheService? = nil,
        librarySnapshotService: (any LibrarySnapshotService)? = nil,
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
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: apiService,
            discogs: apiService,
            appleMusic: apiService
        )

        let coordinator = UpdateCoordinator(
            dependencies: UpdateCoordinatorDependencies(
                apiOrchestrator: orchestrator,
                scriptBridge: bridge,
                trackStore: store,
                cache: cacheService,
                undoCoordinator: undo,
                librarySnapshotService: librarySnapshotService
            ),
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

    @Test("Successful write invalidates cached album year")
    func successfulWriteInvalidatesCachedAlbumYear() async throws {
        let cache = MockCacheService()
        await cache.storeAlbumYear(artist: "Beatles", album: "Abbey Road", year: 1970, confidence: 85)
        let fixture = await makeCoordinator(
            year: 2020,
            confidence: 90,
            cache: cache
        )

        let track = makeEditableTrack(year: 1969)
        _ = try await fixture.coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: false
        )

        let cached = await cache.getAlbumYear(artist: "Beatles", album: "Abbey Road")
        #expect(cached == nil)
    }

    @Test("Successful write invalidates cached API result")
    func successfulWriteInvalidatesCachedAPIResult() async throws {
        let cache = MockCacheService()
        await cache.setCachedAPIResult(CachedAPIResult(
            artist: "Beatles",
            album: "Abbey Road",
            year: 1970,
            source: "musicbrainz",
            timestamp: Date(),
            ttl: nil
        ))
        let fixture = await makeCoordinator(
            year: 2020,
            confidence: 90,
            cache: cache
        )

        let track = makeEditableTrack(year: 1969)
        _ = try await fixture.coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: false
        )

        let cached = await cache.getCachedAPIResult(
            artist: "Beatles",
            album: "Abbey Road",
            source: "musicbrainz"
        )
        #expect(cached == nil)
    }

    @Test("Artist rename write invalidates old and new artist caches")
    func artistRenameWriteInvalidatesOldAndNewArtistCaches() async throws {
        let cache = MockCacheService()
        await seedAlbumCaches(cache, artist: "OldArtist", album: "Album")
        await seedAlbumCaches(cache, artist: "NewArtist", album: "Album")
        let fixture = await makeCoordinator(cache: cache)
        var renamedTrack = makeEditableTrack(artist: "NewArtist", album: "Album")
        renamedTrack.originalArtist = "OldArtist"

        let change = ProposedChange(
            track: renamedTrack,
            changeType: .artistRename,
            oldValue: "OldArtist",
            newValue: "NewArtist",
            confidence: 100,
            source: "Test"
        )
        _ = try await fixture.coordinator.applyAcceptedChanges(
            [change],
            progressHandler: Self.ignoreProgress
        )

        await expectAlbumCachesInvalidated(cache, artist: "OldArtist", album: "Album")
        await expectAlbumCachesInvalidated(cache, artist: "NewArtist", album: "Album")
    }

    @Test("Album cleaning write invalidates old and new album caches")
    func albumCleaningWriteInvalidatesOldAndNewAlbumCaches() async throws {
        let cache = MockCacheService()
        await seedAlbumCaches(cache, artist: "Beatles", album: "Old Album")
        await seedAlbumCaches(cache, artist: "Beatles", album: "New Album")
        let fixture = await makeCoordinator(cache: cache)

        let change = ProposedChange(
            track: makeEditableTrack(artist: "Beatles", album: "Old Album"),
            changeType: .albumCleaning,
            oldValue: "Old Album",
            newValue: "New Album",
            confidence: 100,
            source: "Test"
        )
        _ = try await fixture.coordinator.applyAcceptedChanges(
            [change],
            progressHandler: Self.ignoreProgress
        )

        await expectAlbumCachesInvalidated(cache, artist: "Beatles", album: "Old Album")
        await expectAlbumCachesInvalidated(cache, artist: "Beatles", album: "New Album")
    }

    @Test("Successful write invalidates library snapshot cache")
    func successfulWriteInvalidatesLibrarySnapshotCache() async throws {
        let snapshotService = MockLibrarySnapshotService()
        let fixture = await makeCoordinator(librarySnapshotService: snapshotService)

        let change = ProposedChange(
            track: makeEditableTrack(),
            changeType: .genreUpdate,
            oldValue: "Rock",
            newValue: "Alternative",
            confidence: 100,
            source: "Test"
        )
        _ = try await fixture.coordinator.applyAcceptedChanges(
            [change],
            progressHandler: Self.ignoreProgress
        )

        await #expect(snapshotService.wasCleared())
    }

    @Test("Failed write keeps library snapshot cache")
    func failedWriteKeepsLibrarySnapshotCache() async throws {
        let snapshotService = MockLibrarySnapshotService()
        let bridge = MockAppleScriptClient()
        await bridge.setThrowMode(true)
        let fixture = await makeCoordinator(
            scriptBridge: bridge,
            librarySnapshotService: snapshotService
        )

        let change = ProposedChange(
            track: makeEditableTrack(),
            changeType: .genreUpdate,
            oldValue: "Rock",
            newValue: "Alternative",
            confidence: 100,
            source: "Test"
        )
        await #expect(throws: UpdateCoordinatorError.self) {
            _ = try await fixture.coordinator.applyAcceptedChanges(
                [change],
                progressHandler: Self.ignoreProgress
            )
        }

        await #expect(!snapshotService.wasCleared())
    }

    @Test("Reviewed prerelease changes are skipped without writing")
    func reviewedPrereleaseChangesAreSkippedWithoutWriting() async throws {
        let fixture = await makeCoordinator()
        let change = ProposedChange(
            track: Track(
                id: "T1",
                name: "Track",
                artist: "Artist",
                album: "Album",
                genre: "Rock",
                trackStatus: "prerelease"
            ),
            changeType: .genreUpdate,
            oldValue: "Rock",
            newValue: "Metal",
            confidence: 100,
            source: "Test"
        )

        let result = try await fixture.coordinator.applyAcceptedChanges(
            [change],
            progressHandler: Self.ignoreProgress
        )

        #expect(result.entries.isEmpty)
        #expect(result.failedTrackIDs.isEmpty)
        let written = await fixture.bridge.writtenProperties
        #expect(written.isEmpty)
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

    private func seedAlbumCaches(_ cache: MockCacheService, artist: String, album: String) async {
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

    private func expectAlbumCachesInvalidated(_ cache: MockCacheService, artist: String, album: String) async {
        let albumYear = await cache.getAlbumYear(artist: artist, album: album)
        let apiResult = await cache.getCachedAPIResult(
            artist: artist,
            album: album,
            source: "musicbrainz"
        )
        #expect(albumYear == nil)
        #expect(apiResult == nil)
    }

    @Test("Multi-track update skips non-editable tracks without reporting write failures")
    func multiTrackUpdateSkipsNonEditableTracks() async throws {
        let fixture = await makeCoordinator(year: 2020, confidence: 90)
        let prereleaseTrack = Track(
            id: "prerelease",
            name: "Upcoming Song",
            artist: "Clutch",
            album: "Blast Tyrant",
            year: 2004,
            trackStatus: "prerelease"
        )

        let result = try await fixture.coordinator.updateTracks(
            [prereleaseTrack],
            options: UpdateOptions(updateGenre: false, updateYear: true),
            progressHandler: Self.ignoreProgress
        )

        #expect(result.entries.isEmpty)
        #expect(result.failedTrackIDs.isEmpty)
        #expect(result.errorDescriptions.isEmpty)
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
