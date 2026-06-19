import Foundation
import Testing
@testable import Core
@testable import Services

private struct PendingCoordinatorFixture {
    let coordinator: UpdateCoordinator
    let bridge: MockAppleScriptClient
}

private func makePendingCoordinator(
    year: Int?,
    confidence: Int
) async -> PendingCoordinatorFixture {
    let bridge = MockAppleScriptClient()
    let store = MockTrackStore()
    let cache = MockCacheService()
    let undoDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("UpdateCoordinatorPendingTests-\(UUID().uuidString)")
    let undo = UndoCoordinator(scriptBridge: bridge, directory: undoDir)
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
        runtimeConfiguration: UpdateRuntimeConfiguration()
    )
    return PendingCoordinatorFixture(coordinator: coordinator, bridge: bridge)
}

private func makePendingTrack(
    id: String,
    name: String = "Track",
    artist: String,
    album: String,
    year: Int?
) -> Track {
    Track(
        id: id,
        name: name,
        artist: artist,
        album: album,
        year: year
    )
}

@Suite("UpdateCoordinator - pending verification")
struct PendingVerificationCoordinatorTests {
    @Test("Applies resolved API year to album tracks")
    func appliesResolvedYearToAlbumTracks() async throws {
        let fixture = await makePendingCoordinator(year: 1997, confidence: 55)
        let entry = PendingAlbumEntry(
            id: "deftones-around-the-fur",
            artist: "Deftones",
            album: "Around the Fur",
            reason: "no_year_found"
        )
        let albumTracks = [
            makePendingTrack(
                id: "T1",
                name: "My Own Summer",
                artist: "Deftones",
                album: "Around the Fur",
                year: nil
            ),
            makePendingTrack(
                id: "T2",
                name: "Be Quiet and Drive",
                artist: "Deftones",
                album: "Around the Fur",
                year: 1998
            ),
        ]

        let result = try await fixture.coordinator.verifyPendingAlbum(entry, albumTracks: albumTracks)

        let written = await fixture.bridge.writtenProperties
        #expect(result.resolvedYear == 1997)
        #expect(result.entries.count == 2)
        #expect(written.count == 2)
        #expect(written.allSatisfy { $0.property == "year" && $0.value == "1997" })
    }

    @Test("Leaves album untouched when API has no year")
    func skipsWhenNoYearResolved() async throws {
        let fixture = await makePendingCoordinator(year: nil, confidence: 0)
        let entry = PendingAlbumEntry(
            id: "unknown-album",
            artist: "Unknown",
            album: "Missing",
            reason: "no_year_found"
        )
        let albumTracks = [
            makePendingTrack(id: "T1", artist: "Unknown", album: "Missing", year: nil),
        ]

        let result = try await fixture.coordinator.verifyPendingAlbum(entry, albumTracks: albumTracks)

        let written = await fixture.bridge.writtenProperties
        #expect(result.resolvedYear == nil)
        #expect(result.entries.isEmpty)
        #expect(written.isEmpty)
    }
}
