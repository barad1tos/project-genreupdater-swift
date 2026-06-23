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
        let orchestrator = makeAPIOrchestrator(
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

    @Test("Artist start fallback uses album identity artist for collaborations")
    func artistStartFallbackUsesAlbumIdentityArtistForCollaborations() async throws {
        let apiResult = YearResult(
            year: 1990,
            confidence: 60,
            yearScores: [1990: 60, 2020: 10]
        )
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(yearResult: apiResult),
            discogs: MockAPIService(),
            appleMusic: ArtistStartLookupAPIService(startYearsByArtist: ["daft punk": 2000])
        )
        let coordinator = makeCoordinator(apiOrchestrator: orchestrator)
        let track = Track(
            id: "T1",
            name: "Modern Track",
            artist: "Daft Punk feat. Pharrell Williams",
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

    @Test("Artist start fallback uses track artist instead of album artist")
    func artistStartFallbackUsesTrackArtistInsteadOfAlbumArtist() async throws {
        let apiResult = YearResult(
            year: 1990,
            confidence: 60,
            yearScores: [1990: 60, 2020: 10]
        )
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(yearResult: apiResult),
            discogs: MockAPIService(),
            appleMusic: ArtistStartLookupAPIService(startYearsByArtist: ["modern artist": 2000])
        )
        let coordinator = makeCoordinator(apiOrchestrator: orchestrator)
        let track = Track(
            id: "T1",
            name: "Modern Track",
            artist: "Modern Artist",
            album: "Compilation",
            year: 2020,
            albumArtist: "Various Artists"
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
            dependencies: UpdateCoordinatorDependencies(
                apiOrchestrator: apiOrchestrator,
                scriptBridge: bridge,
                trackStore: store,
                cache: cache,
                undoCoordinator: UndoCoordinator(scriptBridge: bridge, directory: undoDirectory)
            ),
            genreDeterminator: GenreDeterminator(),
            yearDeterminator: YearDeterminator(),
            runtimeConfiguration: UpdateRuntimeConfiguration(
                policies: UpdateRuntimeConfiguration.Policies(minimumYearUpdateConfidence: 30)
            )
        )
    }
}

private struct ArtistStartLookupAPIService: ExternalAPIService {
    let startYearsByArtist: [String: Int]

    func getAlbumYear(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        YearResult()
    }

    func getReleaseCandidates(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> [ReleaseCandidate] {
        []
    }

    func getArtistStartYear(
        normalizedArtist: String
    ) async throws -> Int? {
        startYearsByArtist[normalizedArtist]
    }

    func initialize(force _: Bool) async throws {
        try Task.checkCancellation()
    }
}
