import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("UpdateCoordinator — artist start year parity")
struct UpdateCoordinatorArtistStartTests {
    @Test("Artist start fallback preserves existing year when proposed API year predates artist")
    func artistStartFallbackPreservesExistingYearWhenProposedYearPredatesArtist() async throws {
        let apiResult = YearResult(
            year: 1990,
            confidence: 60,
            yearScores: [1990: 60, 2020: 10]
        )
        let musicBrainz = MockAPIService(yearResult: apiResult)
        let orchestrator = APIOrchestrator(
            musicBrainz: musicBrainz,
            discogs: MockAPIService(),
            appleMusic: MockAPIService(artistStartYear: 2000)
        )
        let coordinator = makeCoordinator(apiOrchestrator: orchestrator)
        let track = Track(
            id: "T1",
            name: "Modern Track",
            artist: "Test Artist",
            album: "Modern Album",
            year: 2020
        )

        let changes = try await coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        #expect(changes.allSatisfy { $0.changeType != .yearUpdate })
    }

    private func makeCoordinator(apiOrchestrator: APIOrchestrator) -> UpdateCoordinator {
        let bridge = MockAppleScriptClient()
        let store = MockTrackStore()
        let cache = MockCacheService()
        let undoDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateCoordinatorArtistStartTests-\(UUID().uuidString)")
        return UpdateCoordinator(
            apiOrchestrator: apiOrchestrator,
            scriptBridge: bridge,
            trackStore: store,
            cache: cache,
            undoCoordinator: UndoCoordinator(scriptBridge: bridge, directory: undoDirectory),
            genreDeterminator: GenreDeterminator(),
            yearDeterminator: YearDeterminator(),
            runtimeConfiguration: UpdateRuntimeConfiguration(minimumYearUpdateConfidence: 30)
        )
    }
}
