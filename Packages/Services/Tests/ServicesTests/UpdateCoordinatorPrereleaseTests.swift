import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("UpdateCoordinator - prerelease preflight")
struct UpdateCoordinatorPrereleaseTests {
    @Test("Marks prerelease tracks pending before AppleScript ID lookup")
    func marksPrereleaseTracksPendingBeforeAppleScriptIDLookup() async throws {
        let track = Track(
            id: "pre-1",
            name: "Future Track",
            artist: "SubRosa",
            album: "Future Album",
            year: nil,
            trackStatus: TrackKind.prerelease.rawValue
        )
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        let apiProbe = APIRequestProbe()
        let api = makeAPIOrchestrator(
            musicBrainz: UpdateCoordinatorRecordingAPIService(probe: apiProbe),
            discogs: UpdateCoordinatorRecordingAPIService(probe: apiProbe),
            appleMusic: UpdateCoordinatorRecordingAPIService(probe: apiProbe)
        )
        let pendingVerification = PendingVerificationProbe(entry: nil, isVerificationNeeded: false)
        let coordinator = makeCoordinator(
            api: api,
            bridge: bridge,
            cache: cache,
            idMapper: MissingTrackIDMapper(),
            pendingVerificationService: pendingVerification
        )

        let changes = try await coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        let markedAlbums = await pendingVerification.markedAlbums
        #expect(changes.isEmpty)
        #expect(await apiProbe.requestCount == 0)
        let markedAlbum = try #require(markedAlbums.first)
        #expect(markedAlbums.count == 1)
        #expect(markedAlbum.artist == "SubRosa")
        #expect(markedAlbum.album == "Future Album")
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
        let editableTrack = Track(
            id: "editable-1",
            name: "Released Track",
            artist: "SubRosa",
            album: "Future Album",
            year: 1999,
            trackStatus: TrackKind.subscription.rawValue
        )
        let prereleaseTrack = Track(
            id: "pre-1",
            name: "Future Track",
            artist: "SubRosa",
            album: "Future Album",
            year: nil,
            trackStatus: TrackKind.prerelease.rawValue
        )
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        await cache.storeAlbumYear(artist: "SubRosa", album: "Future Album", year: 2001, confidence: 95)
        let apiProbe = APIRequestProbe()
        let api = makeAPIOrchestrator(
            musicBrainz: UpdateCoordinatorRecordingAPIService(probe: apiProbe),
            discogs: UpdateCoordinatorRecordingAPIService(probe: apiProbe),
            appleMusic: UpdateCoordinatorRecordingAPIService(probe: apiProbe)
        )
        let pendingVerification = PendingVerificationProbe(entry: nil, isVerificationNeeded: false)
        let coordinator = makeCoordinator(
            api: api,
            bridge: bridge,
            cache: cache,
            pendingVerificationService: pendingVerification
        )

        let changes = try await coordinator.updateTrack(
            editableTrack,
            albumTracks: [editableTrack, prereleaseTrack],
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        let markedAlbums = await pendingVerification.markedAlbums
        let yearChange = try #require(changes.first { $0.changeType == .yearUpdate })
        #expect(yearChange.track.id == "editable-1")
        #expect(yearChange.newValue == "2001")
        #expect(await apiProbe.requestCount == 0)
        let markedAlbum = try #require(markedAlbums.first)
        #expect(markedAlbums.count == 1)
        #expect(markedAlbum.artist == "SubRosa")
        #expect(markedAlbum.album == "Future Album")
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
        let track = Track(
            id: "pre-1",
            name: "Future Track",
            artist: "SubRosa",
            album: "Future Album",
            year: nil,
            trackStatus: TrackKind.prerelease.rawValue
        )
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        let apiProbe = APIRequestProbe()
        let api = makeAPIOrchestrator(
            musicBrainz: UpdateCoordinatorRecordingAPIService(probe: apiProbe),
            discogs: UpdateCoordinatorRecordingAPIService(probe: apiProbe),
            appleMusic: UpdateCoordinatorRecordingAPIService(probe: apiProbe)
        )
        let pendingVerification = PendingVerificationProbe(entry: nil, isVerificationNeeded: false)
        let coordinator = makeCoordinator(
            api: api,
            bridge: bridge,
            cache: cache,
            idMapper: MissingTrackIDMapper(),
            pendingVerificationService: pendingVerification,
            runtimeConfiguration: UpdateRuntimeConfiguration(policies: .init(prereleaseHandling: .skipAll))
        )

        let changes = try await coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        #expect(changes.isEmpty)
        #expect(await apiProbe.requestCount == 0)
        #expect(await pendingVerification.markedAlbums.isEmpty)
    }

    @Test("Mark-only mode marks mixed prerelease albums without processing editable tracks")
    func markOnlyModeMarksMixedPrereleaseAlbumWithoutProcessingEditableTrack() async throws {
        let editableTrack = Track(
            id: "editable-1",
            name: "Released Track",
            artist: "SubRosa",
            album: "Future Album",
            year: 1999,
            trackStatus: TrackKind.subscription.rawValue
        )
        let prereleaseTrack = Track(
            id: "pre-1",
            name: "Future Track",
            artist: "SubRosa",
            album: "Future Album",
            year: nil,
            trackStatus: TrackKind.prerelease.rawValue
        )
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        await cache.storeAlbumYear(artist: "SubRosa", album: "Future Album", year: 2001, confidence: 95)
        let apiProbe = APIRequestProbe()
        let api = makeAPIOrchestrator(
            musicBrainz: UpdateCoordinatorRecordingAPIService(probe: apiProbe),
            discogs: UpdateCoordinatorRecordingAPIService(probe: apiProbe),
            appleMusic: UpdateCoordinatorRecordingAPIService(probe: apiProbe)
        )
        let pendingVerification = PendingVerificationProbe(entry: nil, isVerificationNeeded: false)
        let coordinator = makeCoordinator(
            api: api,
            bridge: bridge,
            cache: cache,
            pendingVerificationService: pendingVerification,
            runtimeConfiguration: UpdateRuntimeConfiguration(policies: .init(prereleaseHandling: .markOnly))
        )

        let changes = try await coordinator.updateTrack(
            editableTrack,
            albumTracks: [editableTrack, prereleaseTrack],
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        let markedAlbums = await pendingVerification.markedAlbums
        #expect(changes.isEmpty)
        #expect(await apiProbe.requestCount == 0)
        let markedAlbum = try #require(markedAlbums.first)
        #expect(markedAlbums.count == 1)
        #expect(markedAlbum.artist == "SubRosa")
        #expect(markedAlbum.album == "Future Album")
        #expect(markedAlbum.reason == "prerelease")
        #expect(markedAlbum.metadata == [
            "editable_count": "1",
            "mode": "mark_only",
            "prerelease_count": "1",
            "track_count": "2",
        ])
        #expect(markedAlbum.recheckDays == 30)
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
