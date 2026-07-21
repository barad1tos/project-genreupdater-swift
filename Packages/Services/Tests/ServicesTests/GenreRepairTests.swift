import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("UpdateCoordinator - genre repair")
struct GenreRepairTests {
    @Test("Unknown genre is repaired like missing genre")
    func unknownGenreIsRepairedLikeMissingGenre() async throws {
        let coordinator = await makeCoordinator()
        let sourceTrack = makeEditableTrack(
            id: "source",
            name: "Source Song",
            artist: "Artist",
            album: "First Album",
            genre: "Post-Punk",
            year: nil,
            dateAdded: Date(timeIntervalSince1970: 100)
        )
        let targetTrack = makeEditableTrack(
            id: "target",
            name: "Unknown Genre Song",
            artist: "Artist",
            album: "Later Album",
            genre: "Unknown",
            year: nil,
            dateAdded: Date(timeIntervalSince1970: 200)
        )

        let changes = try await coordinator.updateTrack(
            targetTrack,
            artistTracks: [sourceTrack, targetTrack],
            options: UpdateOptions(updateGenre: true, updateYear: false),
            dryRun: true
        )

        let genreChange = try #require(changes.first { $0.changeType == .genreUpdate })
        #expect(genreChange.oldValue == "Unknown")
        #expect(genreChange.newValue == "Post-Punk")
    }

    @Test("Unknown genre is not used as repair source")
    func unknownGenreIsNotUsedAsRepairSource() async throws {
        let coordinator = await makeCoordinator()
        let targetTrack = makeEditableTrack(
            id: "target",
            name: "Unknown Genre Song",
            artist: "Artist",
            album: "First Album",
            genre: "Unknown",
            year: nil,
            dateAdded: Date(timeIntervalSince1970: 100)
        )
        let sourceTrack = makeEditableTrack(
            id: "source",
            name: "Source Song",
            artist: "Artist",
            album: "Later Album",
            genre: "Post-Punk",
            year: nil,
            dateAdded: Date(timeIntervalSince1970: 200)
        )

        let changes = try await coordinator.updateTrack(
            targetTrack,
            artistTracks: [targetTrack, sourceTrack],
            options: UpdateOptions(updateGenre: true, updateYear: false),
            dryRun: true
        )

        let genreChange = try #require(changes.first { $0.changeType == .genreUpdate })
        #expect(genreChange.newValue == "Post-Punk")
    }

    private func makeCoordinator() async -> UpdateCoordinator {
        let bridge = MockAppleScriptClient()
        let apiService = MockAPIService()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: apiService,
            discogs: apiService,
            appleMusic: apiService
        )
        let undoDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenreRepairTests-\(UUID().uuidString)")
        let undo = UndoCoordinator(scriptBridge: bridge, directory: undoDirectory)

        return UpdateCoordinator(
            dependencies: UpdateDependencies(
                apiOrchestrator: orchestrator,
                scriptBridge: bridge,
                stores: .init(
                    trackStore: MockTrackStore(),
                    cache: MockCacheService()
                ),
                undoCoordinator: undo
            ),
            genreDeterminator: GenreDeterminator(),
            yearDeterminator: YearDeterminator()
        )
    }
}
