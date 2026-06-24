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

    @Test("Cleaning runs before genre and year decisions")
    func cleaningRunsBeforeGenreAndYearDecisions() async throws {
        let lookupRecorder = AlbumYearLookupRecorder()
        let apiService = RecordingAlbumYearAPIService(
            lookupRecorder: lookupRecorder,
            yearResult: YearResult(
                year: 1968,
                isDefinitive: true,
                confidence: 100,
                yearScores: [1968: 100]
            )
        )
        let runtimeConfiguration = UpdateRuntimeConfiguration(
            policies: UpdateRuntimeConfiguration.Policies(isYearLookupEnabled: true)
        )
        let coordinator = await makeCoordinator(
            runtimeConfiguration: runtimeConfiguration,
            apiService: apiService
        )
        let track = makeTrack(
            id: "target",
            name: "Song (Remastered 2020)",
            album: "Album Remastered",
            genre: nil,
            dateAdded: Date(timeIntervalSince1970: 2000)
        )
        let genreSource = makeTrack(
            id: "genre-source",
            name: "Reference",
            album: "Album",
            genre: "Rock",
            dateAdded: Date(timeIntervalSince1970: 1000)
        )

        let changes = try await coordinator.updateTrack(
            track,
            artistTracks: [genreSource],
            options: UpdateOptions(
                updateGenre: true,
                updateYear: true,
                forceYearLookup: true,
                cleanTrackNames: true,
                cleanAlbumNames: true,
                minConfidence: 0
            ),
            dryRun: true
        )

        #expect(changes.map(\.changeType) == [
            .trackCleaning,
            .albumCleaning,
            .genreUpdate,
            .yearUpdate,
        ])
        #expect(changes.first { $0.changeType == .genreUpdate }?.track.name == "Song (Remastered 2020)")
        #expect(changes.first { $0.changeType == .yearUpdate }?.track.album == "Album Remastered")
        let queriedAlbums = await lookupRecorder.queriedAlbums()
        #expect(!queriedAlbums.isEmpty)
        #expect(queriedAlbums.allSatisfy { $0 == "Album" })
    }

    @Test("Cleaning exceptions use artist rename mappings")
    func cleaningExceptionsUseArtistRenameMappings() async throws {
        var cleaning = CleaningConfig()
        cleaning.trackCleaningExceptions = [
            TrackCleaningException(artist: "Beatles", album: "Album Remastered"),
        ]
        let runtimeConfiguration = UpdateRuntimeConfiguration(
            artistRenameMappings: ["The Beatles": "Beatles"],
            policies: UpdateRuntimeConfiguration.Policies(cleaning: cleaning)
        )
        let coordinator = await makeCoordinator(runtimeConfiguration: runtimeConfiguration)
        let track = makeTrack(
            name: "Song (Remastered 2020)",
            artist: "The Beatles",
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

        #expect(!changes.contains { $0.changeType == .trackCleaning })
        #expect(!changes.contains { $0.changeType == .albumCleaning })
        #expect(changes.contains { $0.changeType == .artistRename })
    }

    @Test("Artist rename is proposed before cleaning while cleaning keeps original proposal identity")
    func artistRenameIsProposedBeforeCleaningWhileCleaningKeepsOriginalProposalIdentity() async throws {
        let runtimeConfiguration = UpdateRuntimeConfiguration(
            artistRenameMappings: ["The Beatles": "Beatles"]
        )
        let coordinator = await makeCoordinator(runtimeConfiguration: runtimeConfiguration)
        let track = makeTrack(
            name: "Song (Remastered 2020)",
            artist: "The Beatles",
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

        #expect(changes.map(\.changeType) == [.artistRename, .trackCleaning, .albumCleaning])
        #expect(changes.first { $0.changeType == .trackCleaning }?.track.artist == "The Beatles")
        #expect(changes.first { $0.changeType == .albumCleaning }?.track.artist == "The Beatles")
    }

    @Test("Empty cleaned album names do not feed year lookup")
    func emptyCleanedAlbumNamesDoNotFeedYearLookup() async throws {
        let lookupRecorder = AlbumYearLookupRecorder()
        let apiService = RecordingAlbumYearAPIService(
            lookupRecorder: lookupRecorder,
            yearResult: YearResult(
                year: 2001,
                isDefinitive: true,
                confidence: 100,
                yearScores: [2001: 100]
            )
        )
        let runtimeConfiguration = UpdateRuntimeConfiguration(
            policies: UpdateRuntimeConfiguration.Policies(isYearLookupEnabled: true)
        )
        let coordinator = await makeCoordinator(
            runtimeConfiguration: runtimeConfiguration,
            apiService: apiService
        )
        let track = makeTrack(
            name: "Song",
            album: "Remastered",
            dateAdded: Date(timeIntervalSince1970: 2000)
        )

        let changes = try await coordinator.updateTrack(
            track,
            options: UpdateOptions(
                updateGenre: false,
                updateYear: true,
                forceYearLookup: true,
                cleanAlbumNames: true,
                minConfidence: 0
            ),
            dryRun: true
        )

        #expect(!changes.contains { $0.changeType == .albumCleaning })
        let queriedAlbums = await lookupRecorder.queriedAlbums()
        #expect(!queriedAlbums.contains(""))
        #expect(queriedAlbums.allSatisfy { $0 == "Remastered" })
    }

    @Test("Cleaning exceptions suppress metadata cleaning changes")
    func cleaningExceptionsSuppressMetadataCleaningChanges() async throws {
        var cleaning = CleaningConfig()
        cleaning.trackCleaningExceptions = [
            TrackCleaningException(artist: "Beatles", album: "Album Remastered"),
        ]
        let runtimeConfiguration = UpdateRuntimeConfiguration(
            policies: UpdateRuntimeConfiguration.Policies(cleaning: cleaning)
        )
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
        runtimeConfiguration: UpdateRuntimeConfiguration = UpdateRuntimeConfiguration(),
        apiService: any ExternalAPIService = MockAPIService()
    ) async -> UpdateCoordinator {
        let scriptBridge = MockAppleScriptClient()
        return UpdateCoordinator(
            dependencies: UpdateCoordinatorDependencies(
                apiOrchestrator: makeAPIOrchestrator(
                    musicBrainz: apiService,
                    discogs: apiService,
                    appleMusic: apiService
                ),
                scriptBridge: scriptBridge,
                trackStore: MockTrackStore(),
                cache: MockCacheService(),
                undoCoordinator: UndoCoordinator(
                    scriptBridge: scriptBridge,
                    directory: FileManager.default.temporaryDirectory
                        .appendingPathComponent("UpdateCoordinatorCleaningTests-\(UUID().uuidString)")
                )
            ),
            genreDeterminator: GenreDeterminator(),
            yearDeterminator: YearDeterminator(),
            runtimeConfiguration: runtimeConfiguration
        )
    }

    private func makeTrack(
        id: String = "T1",
        name: String,
        artist: String = "Beatles",
        album: String,
        genre: String? = "Rock",
        dateAdded: Date? = nil
    ) -> Track {
        Track(
            id: id,
            name: name,
            artist: artist,
            album: album,
            genre: genre,
            year: 1969,
            dateAdded: dateAdded,
            trackStatus: nil
        )
    }
}

private actor AlbumYearLookupRecorder {
    private var albums: [String] = []

    func record(album: String) {
        albums.append(album)
    }

    func queriedAlbums() -> [String] {
        albums
    }
}

private struct RecordingAlbumYearAPIService: ExternalAPIService {
    let lookupRecorder: AlbumYearLookupRecorder
    let yearResult: YearResult

    func getAlbumYear(
        artist _: String,
        album: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        await lookupRecorder.record(album: album)
        return yearResult
    }

    func initialize(force _: Bool) async throws {
        try Task.checkCancellation()
    }
}
