import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("UpdateCoordinator - API release candidate scoring")
struct UpdateCoordinatorCandidateScoringTests {
    @Test("uses API release candidates when legacy YearResult is empty")
    func usesAPIReleaseCandidatesWhenLegacyResultIsEmpty() async throws {
        let track = Track(
            id: "track-1",
            name: "Opening Track",
            artist: "Test Artist",
            album: "Test Album",
            year: nil,
            trackStatus: nil
        )
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        let undoDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateCoordinatorCandidateScoringTests-\(UUID().uuidString)")
        let api = APIOrchestrator(
            musicBrainz: MockAPIService(releaseCandidates: [
                ReleaseCandidate(
                    artist: "Test Artist",
                    album: "Test Album",
                    year: 1998,
                    source: .musicBrainz,
                    mbReleaseGroupFirstYear: 1998
                ),
            ]),
            discogs: MockAPIService(),
            appleMusic: MockAPIService()
        )
        let coordinator = UpdateCoordinator(
            apiOrchestrator: api,
            scriptBridge: bridge,
            trackStore: MockTrackStore(),
            cache: cache,
            undoCoordinator: UndoCoordinator(scriptBridge: bridge, directory: undoDirectory),
            genreDeterminator: GenreDeterminator(),
            yearDeterminator: YearDeterminator()
        )

        let changes = try await coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        let yearChange = try #require(changes.first { $0.changeType == .yearUpdate })
        #expect(yearChange.newValue == "1998")
        #expect(yearChange.source != "API")
    }
}
