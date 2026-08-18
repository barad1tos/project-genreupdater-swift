import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("UpdateCoordinator - prerelease preflight")
struct PrereleasePreflightTests {
    @Test("Marks prerelease tracks pending before AppleScript ID lookup")
    func marksPrereleaseTracksPendingBeforeAppleScriptIDLookup() async throws {
        let track = makePrereleaseTrack()
        let context = makePrereleaseContext(idMapper: MissingTrackIDMapper())

        let changes = try await context.coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        #expect(changes.isEmpty)
        #expect(await context.apiProbe.requestCount == 0)
        let markedAlbum = try await singlePrereleaseMark(in: context)
        #expect(markedAlbum.metadata == [
            "all_prerelease": "true",
            "prerelease_count": "1",
            "track_count": "1",
        ])
    }

    @Test("Marks mixed prerelease albums pending while processing editable tracks")
    func marksMixedPrereleaseAlbumAndProcessesEditableTrack() async throws {
        let editableTrack = makeEditableTrack()
        let prereleaseTrack = makePrereleaseTrack(year: currentUTCYear() + 3)
        let context = makePrereleaseContext()
        await context.cache.storeAlbumYear(
            artist: PrereleaseFixture.artist,
            album: PrereleaseFixture.album,
            year: 2001,
            confidence: 95
        )

        let changes = try await context.coordinator.updateTrack(
            editableTrack,
            albumTracks: [editableTrack, prereleaseTrack],
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        let yearChange = try #require(changes.first { $0.changeType == .yearUpdate })
        #expect(yearChange.track.id == PrereleaseFixture.editableTrackID)
        #expect(yearChange.newValue == "2001")
        #expect(await context.apiProbe.requestCount == 0)
        let markedAlbum = try await singlePrereleaseMark(in: context)
        #expect(markedAlbum.metadata == [
            "editable_count": "1",
            "mixed_album": "true",
            "prerelease_count": "1",
            "track_count": "2",
        ])
    }

    @Test("Skip-all mode skips prerelease albums without marking pending")
    func skipAllModeSkipsPrereleaseAlbumWithoutPendingMark() async throws {
        let track = makePrereleaseTrack()
        let context = makePrereleaseContext(
            idMapper: MissingTrackIDMapper(),
            prereleaseHandling: .skipAll
        )

        let changes = try await context.coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        #expect(changes.isEmpty)
        #expect(await context.apiProbe.requestCount == 0)
        #expect(await context.pendingVerification.markedAlbums.isEmpty)
    }

    @Test("Mark-only mode marks mixed prerelease albums without processing editable tracks")
    func markOnlyModeMarksMixedPrereleaseAlbumWithoutProcessingEditableTrack() async throws {
        let editableTrack = makeEditableTrack()
        let prereleaseTrack = makePrereleaseTrack()
        let context = makePrereleaseContext(prereleaseHandling: .markOnly)
        await context.cache.storeAlbumYear(
            artist: PrereleaseFixture.artist,
            album: PrereleaseFixture.album,
            year: 2001,
            confidence: 95
        )

        let changes = try await context.coordinator.updateTrack(
            editableTrack,
            albumTracks: [editableTrack, prereleaseTrack],
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        #expect(changes.isEmpty)
        #expect(await context.apiProbe.requestCount == 0)
        let markedAlbum = try await singlePrereleaseMark(in: context)
        #expect(markedAlbum.metadata == [
            "editable_count": "1",
            "mode": "mark_only",
            "prerelease_count": "1",
            "track_count": "2",
        ])
    }

    @Test("Suspicious albums stay pending even during forced lookup", arguments: [false, true])
    func blocksSuspiciousAlbum(forceYearLookup: Bool) async throws {
        let tracks = suspiciousTracks()
        let context = makePrereleaseContext()

        let changes = try await context.coordinator.updateTrack(
            tracks[0],
            albumTracks: tracks,
            options: UpdateOptions(
                updateGenre: false,
                updateYear: true,
                forceYearLookup: forceYearLookup
            ),
            dryRun: true
        )

        #expect(changes.isEmpty)
        #expect(await context.apiProbe.requestCount == 0)
        let markedAlbum = try await requireSingleMark(
            in: context,
            album: "EP"
        )
        #expect(markedAlbum.reason == "suspicious_album_name")
        #expect(markedAlbum.metadata == [
            "album_name_length": "2",
            "unique_years": "3",
        ])
        #expect(markedAlbum.recheckDays == nil)
    }

    @Test("Far-future albums stay pending even during forced lookup", arguments: [false, true])
    func blocksFutureYear(forceYearLookup: Bool) async throws {
        let futureYear = currentUTCYear() + 3
        let track = makeYearTrack(id: "future", year: futureYear)
        let context = makePrereleaseContext()

        let changes = try await context.coordinator.updateTrack(
            track,
            albumTracks: [track],
            options: UpdateOptions(
                updateGenre: false,
                updateYear: true,
                forceYearLookup: forceYearLookup
            ),
            dryRun: true
        )

        #expect(changes.isEmpty)
        #expect(await context.apiProbe.requestCount == 0)
        let markedAlbum = try await singlePrereleaseMark(in: context)
        #expect(markedAlbum.metadata == [
            "expected_year": String(futureYear),
            "track_count": "1",
        ])
    }

    @Test("Configured future-year threshold allows lookup inside its window")
    func thresholdAllowsFutureYear() async throws {
        var processing = ProcessingConfig()
        processing.futureYearThreshold = 5
        let futureYear = currentUTCYear() + 3
        let track = makeYearTrack(id: "near-future", year: futureYear)
        let context = makePrereleaseContext(processingConfig: processing)

        _ = try await context.coordinator.updateTrack(
            track,
            albumTracks: [track],
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        #expect(await context.apiProbe.requestCount > 0)
        #expect(await context.pendingVerification.markedAlbums.isEmpty)
    }

    @Test("Disabled prerelease skipping allows far-future lookup")
    func toggleAllowsFutureYear() async throws {
        var processing = ProcessingConfig()
        processing.skipPrerelease = false
        let futureYear = currentUTCYear() + 3
        let track = makeYearTrack(id: "future-enabled", year: futureYear)
        let context = makePrereleaseContext(processingConfig: processing)

        _ = try await context.coordinator.updateTrack(
            track,
            albumTracks: [track],
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        #expect(await context.apiProbe.requestCount > 0)
        #expect(await context.pendingVerification.markedAlbums.isEmpty)
    }

    @Test("Configured album-name limit allows a longer short album")
    func nameLimitApplied() async throws {
        var processing = ProcessingConfig()
        processing.suspiciousAlbumMinLen = 1
        let tracks = suspiciousTracks()
        let context = makePrereleaseContext(processingConfig: processing)

        _ = try await context.coordinator.updateTrack(
            tracks[0],
            albumTracks: tracks,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        #expect(await context.apiProbe.requestCount > 0)
        #expect(await context.pendingVerification.markedAlbums.isEmpty)
    }

    @Test("Configured unique-year limit allows an album below the new count")
    func yearLimitApplied() async throws {
        var processing = ProcessingConfig()
        processing.suspiciousManyYears = 4
        let tracks = suspiciousTracks()
        let context = makePrereleaseContext(processingConfig: processing)

        _ = try await context.coordinator.updateTrack(
            tracks[0],
            albumTracks: tracks,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        #expect(await context.apiProbe.requestCount > 0)
        #expect(await context.pendingVerification.markedAlbums.isEmpty)
    }

    private func singlePrereleaseMark(
        in context: PrereleaseTestContext
    ) async throws -> PendingVerificationMark {
        let markedAlbum = try await requireSingleMark(
            in: context,
            album: PrereleaseFixture.album
        )
        #expect(markedAlbum.reason == "prerelease")
        #expect(markedAlbum.recheckDays == 30)
        return markedAlbum
    }

    private func requireSingleMark(
        in context: PrereleaseTestContext,
        album: String
    ) async throws -> PendingVerificationMark {
        let markedAlbums = await context.pendingVerification.markedAlbums
        let markedAlbum = try #require(markedAlbums.first)
        #expect(markedAlbums.count == 1)
        #expect(markedAlbum.artist == PrereleaseFixture.artist)
        #expect(markedAlbum.album == album)
        return markedAlbum
    }

    private func makePrereleaseContext(
        idMapper: (any TrackIDMapping)? = nil,
        prereleaseHandling: PrereleaseHandling = .processEditable,
        processingConfig: ProcessingConfig = ProcessingConfig()
    ) -> PrereleaseTestContext {
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        let apiProbe = APIRequestProbe()
        let pendingVerification = PendingVerificationProbe(entry: nil, isVerificationNeeded: false)
        let runtimeConfiguration = UpdateRuntimeConfiguration(
            policies: .init(prereleaseHandling: prereleaseHandling)
        )
        let coordinator = makeCoordinator(
            api: makeAPI(probe: apiProbe),
            bridge: bridge,
            cache: cache,
            idMapper: idMapper,
            pendingVerificationService: pendingVerification,
            runtimeConfiguration: runtimeConfiguration,
            processingConfig: processingConfig
        )

        return PrereleaseTestContext(
            coordinator: coordinator,
            cache: cache,
            apiProbe: apiProbe,
            pendingVerification: pendingVerification
        )
    }

    private func makeAPI(probe: APIRequestProbe) -> APIOrchestrator {
        makeAPIOrchestrator(
            musicBrainz: UpdateAPIDouble(probe: probe),
            discogs: UpdateAPIDouble(probe: probe),
            appleMusic: UpdateAPIDouble(probe: probe)
        )
    }

    private func makeCoordinator(
        api: APIOrchestrator,
        bridge: MockAppleScriptClient,
        cache: MockCacheService,
        idMapper: (any TrackIDMapping)? = nil,
        pendingVerificationService: (any PendingVerificationService)? = nil,
        runtimeConfiguration: UpdateRuntimeConfiguration = UpdateRuntimeConfiguration(),
        processingConfig: ProcessingConfig = ProcessingConfig()
    ) -> UpdateCoordinator {
        let undoDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrereleasePreflightTests-\(UUID().uuidString)")
        return UpdateCoordinator(
            dependencies: UpdateDependencies(
                apiOrchestrator: api,
                scriptBridge: bridge,
                stores: .init(
                    trackStore: MockTrackStore(),
                    cache: cache
                ),
                undoCoordinator: UndoCoordinator(
                    scriptBridge: bridge,
                    directory: undoDirectory
                ),
                idMapper: idMapper,
                pendingVerificationService: pendingVerificationService
            ),
            genreDeterminator: GenreDeterminator(),
            yearDeterminator: YearDeterminator(processingConfig: processingConfig),
            runtimeConfiguration: runtimeConfiguration
        )
    }

    private func makePrereleaseTrack(year: Int? = nil) -> Track {
        Track(
            id: PrereleaseFixture.prereleaseTrackID,
            name: "Future Track",
            artist: PrereleaseFixture.artist,
            album: PrereleaseFixture.album,
            year: year,
            trackStatus: TrackKind.prerelease.rawValue
        )
    }

    private func makeEditableTrack() -> Track {
        Track(
            id: PrereleaseFixture.editableTrackID,
            name: "Released Track",
            artist: PrereleaseFixture.artist,
            album: PrereleaseFixture.album,
            year: 1999,
            trackStatus: TrackKind.subscription.rawValue
        )
    }

    private func makeYearTrack(
        id: String,
        album: String = PrereleaseFixture.album,
        year: Int
    ) -> Track {
        Track(
            id: id,
            name: "Year Track",
            artist: PrereleaseFixture.artist,
            album: album,
            year: year,
            trackStatus: TrackKind.subscription.rawValue
        )
    }

    private func suspiciousTracks() -> [Track] {
        [
            makeYearTrack(id: "suspicious-1", album: "EP", year: 2000),
            makeYearTrack(id: "suspicious-2", album: "EP", year: 2001),
            makeYearTrack(id: "suspicious-3", album: "EP", year: 2002),
        ]
    }

    private func currentUTCYear() -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.component(.year, from: Date())
    }

    private struct PrereleaseTestContext {
        let coordinator: UpdateCoordinator
        let cache: MockCacheService
        let apiProbe: APIRequestProbe
        let pendingVerification: PendingVerificationProbe
    }

    private enum PrereleaseFixture {
        static let artist = "SubRosa"
        static let album = "Future Album"
        static let prereleaseTrackID = "pre-1"
        static let editableTrackID = "editable-1"
    }

    private struct MissingTrackIDMapper: TrackIDMapping {
        func appleScriptID(forMusicKitID _: String) async -> String? {
            nil
        }

        func trackWithAppleScriptMetadata(for _: Track) async -> Track? {
            nil
        }

        func refreshMapping(musicKitTracks _: [Track], appleScriptTracks _: [Track]) async {
            await Task.yield()
        }

        func hasMappingFor(musicKitID _: String) async -> Bool {
            false
        }
    }
}
