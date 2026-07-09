import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("UpdateCoordinator — test artist scope")
struct TestArtistScopeTests {
    @Test("Test artist allow-list skips out-of-scope write mode updates")
    func artistAllowListSkipsOutOfScopeWriteModeUpdates() async throws {
        let fixture = await makeCoordinator(year: 2020, confidence: 90)

        let track = makeEditableTrack(artist: "Beatles", year: 1969)
        let changes = try await fixture.coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: false
        )

        #expect(changes.isEmpty)
        let written = await fixture.bridge.writtenProperties
        #expect(written.isEmpty)
    }

    @Test("Test artist allow-list trims blanks and matches case-insensitively")
    func artistAllowListNormalizesConfiguredArtists() {
        let scopedConfiguration = UpdateRuntimeConfiguration(
            testArtists: [" In Flames ", "", "in flames"]
        )
        let blankOnlyConfiguration = UpdateRuntimeConfiguration(testArtists: ["  "])

        #expect(scopedConfiguration.allowsTrack(makeEditableTrack(artist: "IN FLAMES", year: nil)))
        #expect(!scopedConfiguration.allowsTrack(makeEditableTrack(artist: "Beatles", year: nil)))
        #expect(blankOnlyConfiguration.allowsTrack(makeEditableTrack(artist: "Beatles", year: nil)))
    }

    private func makeCoordinator(
        year: Int?,
        confidence: Int
    ) async -> TestArtistScopeFixture {
        let bridge = MockAppleScriptClient()
        let store = MockTrackStore()
        let cache = MockCacheService()
        let undoDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestArtistScopeTests-\(UUID().uuidString)")
        let undo = UndoCoordinator(scriptBridge: bridge, directory: undoDirectory)
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
                cache: cache,
                undoCoordinator: undo
            ),
            genreDeterminator: GenreDeterminator(),
            yearDeterminator: YearDeterminator(),
            runtimeConfiguration: UpdateRuntimeConfiguration(testArtists: ["In Flames"])
        )

        return TestArtistScopeFixture(coordinator: coordinator, bridge: bridge)
    }

    private func makeEditableTrack(
        artist: String,
        year: Int?
    ) -> Track {
        Track(
            id: "T1",
            name: "Come Together",
            artist: artist,
            album: "Abbey Road",
            genre: "Rock",
            year: year,
            trackStatus: nil
        )
    }
}

private struct TestArtistScopeFixture {
    let coordinator: UpdateCoordinator
    let bridge: MockAppleScriptClient
}
