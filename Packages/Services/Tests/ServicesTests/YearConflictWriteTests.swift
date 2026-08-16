import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("UpdateCoordinator year conflict writes")
struct YearConflictWriteTests {
    @Test("Force lookup keeps release-year conflict safety at the write boundary")
    func forceLookupKeepsReleaseYearConflictSafety() async throws {
        let target = subRosaTrack()
        let peer = subRosaTrack(id: "subrosa-2", name: "Crucible")
        let bridge = MockAppleScriptClient()
        let coordinator = makeCoordinator(bridge: bridge)

        let changes = try await coordinator.updateTrack(
            target,
            albumTracks: [target, peer],
            options: UpdateOptions(updateGenre: false, updateYear: true, forceYearLookup: true),
            dryRun: false
        )

        #expect(!changes.contains { $0.changeType == .yearUpdate })
        #expect(await bridge.writtenProperties.isEmpty)
    }

    private func subRosaTrack(
        id: String = "subrosa-1",
        name: String = "Sugar Creek"
    ) -> Track {
        Track(
            id: id,
            name: name,
            artist: "SubRosa",
            album: "Strega",
            year: 2023,
            releaseYear: 2008
        )
    }

    private func makeCoordinator(bridge: MockAppleScriptClient) -> UpdateCoordinator {
        let api = makeAPIOrchestrator(
            musicBrainz: MockAPIService(releaseCandidates: [
                ReleaseCandidate(
                    artist: "SubRosa",
                    album: "Strega",
                    year: 2010,
                    source: .musicBrainz,
                    mbReleaseGroupFirstYear: 2010
                ),
            ]),
            discogs: MockAPIService(),
            appleMusic: MockAPIService()
        )
        let undoDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YearConflictWriteTests-\(UUID().uuidString)")
        return UpdateCoordinator(
            dependencies: UpdateDependencies(
                apiOrchestrator: api,
                scriptBridge: bridge,
                stores: .init(
                    trackStore: MockTrackStore(),
                    cache: MockCacheService()
                ),
                undoCoordinator: UndoCoordinator(
                    scriptBridge: bridge,
                    directory: undoDirectory
                )
            ),
            genreDeterminator: GenreDeterminator(),
            yearDeterminator: YearDeterminator()
        )
    }
}
