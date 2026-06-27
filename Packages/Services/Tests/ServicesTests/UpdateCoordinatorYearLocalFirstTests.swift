import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("UpdateCoordinator — local-first year repair")
struct UpdateCoordinatorYearLocalFirstTests {
    /// Coordinator whose API orchestrator yields no usable year, reproducing an
    /// album absent from external catalogs (the runtime case that surfaced this).
    private func makeCoordinator() async -> UpdateCoordinator {
        let bridge = MockAppleScriptClient()
        let undoDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YearLocalFirstTests-\(UUID().uuidString)")
        let apiService = MockAPIService(
            yearResult: YearResult(year: nil, confidence: 0, yearScores: [:])
        )
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: apiService,
            discogs: apiService,
            appleMusic: apiService
        )

        return UpdateCoordinator(
            dependencies: UpdateCoordinatorDependencies(
                apiOrchestrator: orchestrator,
                scriptBridge: bridge,
                trackStore: MockTrackStore(),
                cache: MockCacheService(),
                undoCoordinator: UndoCoordinator(scriptBridge: bridge, directory: undoDirectory),
                idMapper: nil,
                librarySnapshotService: nil
            ),
            genreDeterminator: GenreDeterminator(),
            yearDeterminator: YearDeterminator(),
            runtimeConfiguration: UpdateRuntimeConfiguration()
        )
    }

    private func albumTrack(id: String, name: String, year: Int, releaseYear: Int) -> Track {
        Track(
            id: id,
            name: name,
            artist: "паліндром",
            album: "Декілька пісень невизначеності (ч.1)",
            genre: "Alternative",
            year: year,
            trackStatus: nil, // nil trackStatus = available/editable
            releaseYear: releaseYear,
            albumArtist: "паліндром"
        )
    }

    @Test("Repairs a valid outlier year from the album dominant without an API result")
    func repairsValidOutlierFromDominantWithoutAPI() async throws {
        let coordinator = await makeCoordinator()

        let outlier = albumTrack(id: "MK-zabuty", name: "Забути", year: 2024, releaseYear: 2026)
        let consistent = (1 ... 6).map {
            albumTrack(id: "MK-\($0)", name: "Track \($0)", year: 2026, releaseYear: 2026)
        }
        let albumTracks = [outlier] + consistent

        let change = try await coordinator.determineYearChange(
            track: outlier,
            albumTracks: albumTracks,
            forceYearLookup: false
        )

        let yearChange = try #require(change)
        #expect(yearChange.changeType == .yearUpdate)
        #expect(yearChange.oldValue == "2024")
        #expect(yearChange.newValue == "2026")
    }

    @Test("Does not repair when the album year signal is ambiguous")
    func skipsRepairWhenAlbumYearAmbiguous() async throws {
        let coordinator = await makeCoordinator()

        // No dominant (3-way split) and no release-year consensus (varied
        // releaseYears → ambiguous signal) → must defer to the API, not guess.
        let outlier = albumTrack(id: "MK-a", name: "A", year: 2024, releaseYear: 2018)
        let mixed = [
            albumTrack(id: "MK-b", name: "B", year: 2019, releaseYear: 2019),
            albumTrack(id: "MK-c", name: "C", year: 2020, releaseYear: 2020),
        ]
        let albumTracks = [outlier] + mixed

        let change = try await coordinator.determineYearChange(
            track: outlier,
            albumTracks: albumTracks,
            forceYearLookup: false
        )

        #expect(change == nil)
    }
}
