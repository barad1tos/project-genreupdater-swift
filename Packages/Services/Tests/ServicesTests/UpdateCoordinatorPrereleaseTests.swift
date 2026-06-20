import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("UpdateCoordinator - prerelease preflight")
struct UpdateCoordinatorPrereleaseTests {
    @Test("Marks prerelease tracks pending without API lookup")
    func marksPrereleaseTracksPendingWithoutAPILookup() async throws {
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

    private func makeCoordinator(
        api: APIOrchestrator,
        bridge: MockAppleScriptClient,
        cache: MockCacheService,
        pendingVerificationService: (any PendingVerificationService)? = nil
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
                pendingVerificationService: pendingVerificationService
            ),
            genreDeterminator: GenreDeterminator(),
            yearDeterminator: YearDeterminator()
        )
    }
}
