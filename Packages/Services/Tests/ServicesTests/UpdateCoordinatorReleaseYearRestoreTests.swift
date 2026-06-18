import Foundation
import Testing
@testable import Core
@testable import Services

private struct ReleaseYearRestoreFixture {
    let coordinator: UpdateCoordinator
    let bridge: MockAppleScriptClient
}

private func makeReleaseYearRestoreFixture(
    runtimeConfiguration: UpdateRuntimeConfiguration = UpdateRuntimeConfiguration()
) async -> ReleaseYearRestoreFixture {
    let bridge = MockAppleScriptClient()
    let store = MockTrackStore()
    let cache = MockCacheService()
    let undoDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("UpdateCoordinatorReleaseYearRestoreTests-\(UUID().uuidString)")
    let undo = UndoCoordinator(scriptBridge: bridge, directory: undoDirectory)
    let apiService = MockAPIService()
    let orchestrator = APIOrchestrator(
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
        runtimeConfiguration: runtimeConfiguration
    )
    return ReleaseYearRestoreFixture(coordinator: coordinator, bridge: bridge)
}

private func makeReleaseYearTrack(
    id: String,
    artist: String = "Crematory",
    album: String = "Awake",
    year: Int?,
    releaseYear: Int?
) -> Track {
    Track(
        id: id,
        name: "Track \(id)",
        artist: artist,
        album: album,
        year: year,
        releaseYear: releaseYear
    )
}

@Suite("UpdateCoordinator - release year restore")
struct UpdateCoordinatorReleaseYearRestoreTests {
    @Test("Restores tracks whose year differs from release year beyond threshold")
    func restoresTracksBeyondThreshold() async {
        let fixture = await makeReleaseYearRestoreFixture()
        let tracks = [
            makeReleaseYearTrack(id: "T1", year: 2025, releaseYear: 1997),
            makeReleaseYearTrack(id: "T2", year: 2025, releaseYear: 1997),
            makeReleaseYearTrack(id: "T3", year: 2020, releaseYear: 2019),
            makeReleaseYearTrack(id: "T4", year: 2025, releaseYear: nil),
        ]

        let result = await fixture.coordinator.restoreReleaseYears(
            in: tracks,
            threshold: 5,
            progressHandler: ignoreReleaseYearProgress
        )

        let written = await fixture.bridge.writtenProperties
        #expect(result.entries.count == 2)
        #expect(result.failedTrackIDs.isEmpty)
        #expect(result.entries.allSatisfy { $0.changeType == .yearRevert })
        #expect(written.count == 2)
        #expect(written.allSatisfy { $0.property == "year" && $0.value == "1997" })
    }

    @Test("Does not restore when difference equals threshold")
    func skipsExactThreshold() async {
        let fixture = await makeReleaseYearRestoreFixture()
        let tracks = [
            makeReleaseYearTrack(id: "T1", year: 2020, releaseYear: 2015),
        ]

        let result = await fixture.coordinator.restoreReleaseYears(
            in: tracks,
            threshold: 5,
            progressHandler: ignoreReleaseYearProgress
        )

        let written = await fixture.bridge.writtenProperties
        #expect(result.entries.isEmpty)
        #expect(written.isEmpty)
    }

    @Test("Restores missing year when release year exists")
    func restoresMissingYear() async {
        let fixture = await makeReleaseYearRestoreFixture()
        let tracks = [
            makeReleaseYearTrack(id: "T1", year: nil, releaseYear: 1997),
        ]

        let result = await fixture.coordinator.restoreReleaseYears(
            in: tracks,
            threshold: 5,
            progressHandler: ignoreReleaseYearProgress
        )

        let written = await fixture.bridge.writtenProperties
        #expect(result.entries.count == 1)
        #expect(written.first?.value == "1997")
    }

    @Test("Skips out-of-scope restore without recording success")
    func skipsOutOfScopeRestoreWithoutRecordingSuccess() async {
        let fixture = await makeReleaseYearRestoreFixture(
            runtimeConfiguration: UpdateRuntimeConfiguration(testArtists: ["In Flames"])
        )
        let tracks = [
            makeReleaseYearTrack(id: "T1", artist: "Crematory", year: 2025, releaseYear: 1997),
            makeReleaseYearTrack(id: "T2", artist: "Crematory", year: 2025, releaseYear: 1997),
        ]

        let result = await fixture.coordinator.restoreReleaseYears(
            in: tracks,
            threshold: 5,
            progressHandler: ignoreReleaseYearProgress
        )

        let written = await fixture.bridge.writtenProperties
        #expect(result.entries.isEmpty)
        #expect(result.failedTrackIDs.isEmpty)
        #expect(written.isEmpty)
    }
}

private func ignoreReleaseYearProgress(_ update: ProgressUpdate) {
    _ = update
}
