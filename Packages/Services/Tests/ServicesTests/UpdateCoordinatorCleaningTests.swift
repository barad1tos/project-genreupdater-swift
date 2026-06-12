import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("UpdateCoordinator — metadata cleaning")
struct UpdateCoordinatorCleaningTests {
    @Test("Cleaning options propose track and album changes")
    func cleaningOptionsProposeMetadataChanges() async throws {
        let coordinator = await makeCoordinator()
        let track = makeTrack(
            name: "Song (Remastered 2020)",
            album: "Album Remastered"
        )

        let changes = try await coordinator.updateTrack(
            track,
            options: UpdateOptions(
                updateGenre: false,
                updateYear: false,
                cleanTrackNames: true,
                cleanAlbumNames: true,
                minConfidence: 0
            ),
            dryRun: true
        )

        let trackCleaning = changes.first { $0.changeType == .trackCleaning }
        let albumCleaning = changes.first { $0.changeType == .albumCleaning }
        #expect(trackCleaning?.oldValue == "Song (Remastered 2020)")
        #expect(trackCleaning?.newValue == "Song")
        #expect(albumCleaning?.oldValue == "Album Remastered")
        #expect(albumCleaning?.newValue == "Album")
    }

    @Test("Cleaning exceptions suppress metadata cleaning changes")
    func cleaningExceptionsSuppressMetadataCleaningChanges() async throws {
        var cleaning = CleaningConfig()
        cleaning.trackCleaningExceptions = [
            TrackCleaningException(artist: "Beatles", album: "Album Remastered"),
        ]
        let runtimeConfiguration = UpdateRuntimeConfiguration(cleaning: cleaning)
        let coordinator = await makeCoordinator(runtimeConfiguration: runtimeConfiguration)
        let track = makeTrack(
            name: "Song (Remastered 2020)",
            album: "Album Remastered"
        )

        let changes = try await coordinator.updateTrack(
            track,
            options: UpdateOptions(
                updateGenre: false,
                updateYear: false,
                cleanTrackNames: true,
                cleanAlbumNames: true,
                minConfidence: 0
            ),
            dryRun: true
        )

        #expect(changes.isEmpty)
    }

    @Test("Legacy configuration exceptions suppress metadata cleaning changes")
    func legacyConfigurationExceptionsSuppressMetadataCleaningChanges() async throws {
        var configuration = AppConfiguration()
        configuration.exceptions.trackCleaning = [
            TrackCleaningException(artist: "Beatles", album: "Album Remastered"),
        ]
        let runtimeConfiguration = UpdateRuntimeConfiguration(configuration: configuration)
        let coordinator = await makeCoordinator(runtimeConfiguration: runtimeConfiguration)
        let track = makeTrack(
            name: "Song (Remastered 2020)",
            album: "Album Remastered"
        )

        let changes = try await coordinator.updateTrack(
            track,
            options: UpdateOptions(
                updateGenre: false,
                updateYear: false,
                cleanTrackNames: true,
                cleanAlbumNames: true,
                minConfidence: 0
            ),
            dryRun: true
        )

        #expect(changes.isEmpty)
    }

    private func makeCoordinator(
        runtimeConfiguration: UpdateRuntimeConfiguration = UpdateRuntimeConfiguration()
    ) async -> UpdateCoordinator {
        let apiService = MockAPIService()
        return UpdateCoordinator(
            apiOrchestrator: APIOrchestrator(
                musicBrainz: apiService,
                discogs: apiService,
                appleMusic: apiService
            ),
            scriptBridge: MockAppleScriptClient(),
            trackStore: MockTrackStore(),
            cache: MockCacheService(),
            undoCoordinator: UndoCoordinator(
                scriptBridge: MockAppleScriptClient(),
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("UpdateCoordinatorCleaningTests-\(UUID().uuidString)")
            ),
            genreDeterminator: GenreDeterminator(),
            yearDeterminator: YearDeterminator(),
            runtimeConfiguration: runtimeConfiguration
        )
    }

    private func makeTrack(name: String, album: String) -> Track {
        Track(
            id: "T1",
            name: name,
            artist: "Beatles",
            album: album,
            genre: "Rock",
            year: 1969,
            trackStatus: nil
        )
    }
}
