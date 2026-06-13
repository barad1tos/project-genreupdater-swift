import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("UpdateCoordinator — accepted review application")
struct UpdateCoordinatorApplyAcceptedTests {
    @Test("Applying reviewed changes writes only accepted proposals")
    func applyingReviewedChangesWritesOnlyAcceptedProposals() async throws {
        let fixture = await makeCoordinator()
        let track = makeEditableTrack(id: "MK1", genre: "Rock", year: 1969)
        let proposals = [
            ProposedChange(
                track: track,
                changeType: .genreUpdate,
                oldValue: "Rock",
                newValue: "Electronic",
                confidence: 80,
                source: "Library",
                isAccepted: true
            ),
            ProposedChange(
                track: track,
                changeType: .yearUpdate,
                oldValue: "1969",
                newValue: "1970",
                confidence: 95,
                source: "MusicBrainz",
                isAccepted: false
            ),
        ]

        let result = try await fixture.coordinator.applyAcceptedChanges(proposals)

        let written = await fixture.bridge.writtenProperties
        #expect(written.count == 1)
        #expect(written[0].property == "genre")
        #expect(written[0].value == "Electronic")
        #expect(result.entries.count == 1)
        #expect(result.entries[0].changeType == .genreUpdate)
    }

    private func makeCoordinator() async -> AcceptedApplyFixture {
        let bridge = MockAppleScriptClient()
        let apiService = MockAPIService()
        let orchestrator = APIOrchestrator(
            musicBrainz: apiService,
            discogs: apiService,
            appleMusic: apiService
        )
        let undoDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateCoordinatorApplyAcceptedTests-\(UUID().uuidString)")
        let undo = UndoCoordinator(scriptBridge: bridge, directory: undoDir)
        let coordinator = UpdateCoordinator(
            apiOrchestrator: orchestrator,
            scriptBridge: bridge,
            trackStore: MockTrackStore(),
            cache: MockCacheService(),
            undoCoordinator: undo,
            genreDeterminator: GenreDeterminator(),
            yearDeterminator: YearDeterminator()
        )

        return AcceptedApplyFixture(coordinator: coordinator, bridge: bridge)
    }

    private func makeEditableTrack(
        id: String,
        genre: String?,
        year: Int?
    ) -> Track {
        Track(
            id: id,
            name: "Come Together",
            artist: "Beatles",
            album: "Abbey Road",
            genre: genre,
            year: year,
            trackStatus: nil
        )
    }
}

private struct AcceptedApplyFixture {
    let coordinator: UpdateCoordinator
    let bridge: MockAppleScriptClient
}
