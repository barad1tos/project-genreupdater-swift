import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("UpdateCoordinator - prerelease preflight")
struct UpdateCoordinatorPrereleaseTests {
    @Test("Marks prerelease tracks pending before AppleScript ID lookup")
    func marksPrereleaseTracksPendingBeforeAppleScriptIDLookup() async throws {
        let track = makePrereleaseTrack()
        let context = makePrereleaseContext(idMapper: MissingTrackIDMapper())

        let changes = try await context.coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        let markedAlbums = await context.pendingVerification.markedAlbums
        #expect(changes.isEmpty)
        #expect(await context.apiProbe.requestCount == 0)
        let markedAlbum = try #require(markedAlbums.first)
        #expect(markedAlbums.count == 1)
        #expect(markedAlbum.artist == PrereleaseFixture.artist)
        #expect(markedAlbum.album == PrereleaseFixture.album)
        #expect(markedAlbum.reason == "prerelease")
        #expect(markedAlbum.metadata == [
            "all_prerelease": "true",
            "prerelease_count": "1",
            "track_count": "1",
        ])
        #expect(markedAlbum.recheckDays == 30)
    }

    @Test("Marks mixed prerelease albums pending while processing editable tracks")
    func marksMixedPrereleaseAlbumAndProcessesEditableTrack() async throws {
        let editableTrack = makeEditableTrack()
        let prereleaseTrack = makePrereleaseTrack()
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

        let markedAlbums = await context.pendingVerification.markedAlbums
        let yearChange = try #require(changes.first { $0.changeType == .yearUpdate })
        #expect(yearChange.track.id == PrereleaseFixture.editableTrackID)
        #expect(yearChange.newValue == "2001")
        #expect(await context.apiProbe.requestCount == 0)
        let markedAlbum = try #require(markedAlbums.first)
        #expect(markedAlbums.count == 1)
        #expect(markedAlbum.artist == PrereleaseFixture.artist)
        #expect(markedAlbum.album == PrereleaseFixture.album)
        #expect(markedAlbum.reason == "prerelease")
        #expect(markedAlbum.metadata == [
            "editable_count": "1",
            "mixed_album": "true",
            "prerelease_count": "1",
            "track_count": "2",
        ])
        #expect(markedAlbum.recheckDays == 30)
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

        let markedAlbums = await context.pendingVerification.markedAlbums
        #expect(changes.isEmpty)
        #expect(await context.apiProbe.requestCount == 0)
        let markedAlbum = try #require(markedAlbums.first)
        #expect(markedAlbums.count == 1)
        #expect(markedAlbum.artist == PrereleaseFixture.artist)
        #expect(markedAlbum.album == PrereleaseFixture.album)
        #expect(markedAlbum.reason == "prerelease")
        #expect(markedAlbum.metadata == [
            "editable_count": "1",
            "mode": "mark_only",
            "prerelease_count": "1",
            "track_count": "2",
        ])
        #expect(markedAlbum.recheckDays == 30)
    }

    private func makePrereleaseContext(
        idMapper: (any TrackIDMapping)? = nil,
        prereleaseHandling: PrereleaseHandling = .processEditable
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
            runtimeConfiguration: runtimeConfiguration
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
            musicBrainz: UpdateCoordinatorRecordingAPIService(probe: probe),
            discogs: UpdateCoordinatorRecordingAPIService(probe: probe),
            appleMusic: UpdateCoordinatorRecordingAPIService(probe: probe)
        )
    }

    private func makeCoordinator(
        api: APIOrchestrator,
        bridge: MockAppleScriptClient,
        cache: MockCacheService,
        idMapper: (any TrackIDMapping)? = nil,
        pendingVerificationService: (any PendingVerificationService)? = nil,
        runtimeConfiguration: UpdateRuntimeConfiguration = UpdateRuntimeConfiguration()
    ) -> UpdateCoordinator {
        let undoDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateCoordinatorPrereleaseTests-\(UUID().uuidString)")
        return UpdateCoordinator(
            dependencies: UpdateCoordinatorDependencies(
                apiOrchestrator: api,
                scriptBridge: bridge,
                trackStore: MockTrackStore(),
                cache: cache,
                undoCoordinator: UndoCoordinator(scriptBridge: bridge, directory: undoDirectory),
                idMapper: idMapper,
                pendingVerificationService: pendingVerificationService
            ),
            genreDeterminator: GenreDeterminator(),
            yearDeterminator: YearDeterminator(),
            runtimeConfiguration: runtimeConfiguration
        )
    }

    private func makePrereleaseTrack() -> Track {
        Track(
            id: PrereleaseFixture.prereleaseTrackID,
            name: "Future Track",
            artist: PrereleaseFixture.artist,
            album: PrereleaseFixture.album,
            year: nil,
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
