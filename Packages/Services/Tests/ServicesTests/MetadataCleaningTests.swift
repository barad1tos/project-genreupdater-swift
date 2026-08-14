import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("UpdateCoordinator — metadata cleaning")
struct MetadataCleaningTests {
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

    @Test("year-only pass proposes the local album year without other metadata changes")
    func yearOnlyPassProposesOnlyYear() async throws {
        let runtimeConfiguration = UpdateRuntimeConfiguration(
            artistRenameMappings: ["Clutch feat. Guest": "Clutch"]
        )
        let coordinator = await makeCoordinator(runtimeConfiguration: runtimeConfiguration)
        let target = makeTrack(
            id: "blast-target",
            name: "Profits of Doom (Remastered 2020)",
            artist: "Clutch feat. Guest",
            album: "Blast Tyrant Remastered",
            genre: nil,
            year: nil
        )
        let albumTracks = [
            target,
            makeTrack(
                id: "blast-1",
                name: "Mercury",
                artist: target.artist,
                album: target.album,
                genre: "Stoner Rock",
                year: 2004
            ),
            makeTrack(
                id: "blast-2",
                name: "The Mob Goes Wild",
                artist: target.artist,
                album: target.album,
                genre: "Stoner Rock",
                year: 2004
            ),
            makeTrack(
                id: "blast-3",
                name: "Cypress Grove",
                artist: target.artist,
                album: target.album,
                genre: "Stoner Rock",
                year: 2004
            ),
        ]

        let changes = try await coordinator.updateTrack(
            target,
            albumTracks: albumTracks,
            artistTracks: albumTracks,
            options: UpdateOptions(
                updateGenre: true,
                updateYear: true,
                cleanTrackNames: true,
                cleanAlbumNames: true,
                minConfidence: 60
            ),
            pass: .yearOnly,
            dryRun: true
        )

        #expect(changes.map(\.changeType) == [.yearUpdate])
        #expect(changes.first?.newValue == "2004")
        #expect(changes.first?.source == "Dominant")
    }

    @Test("Year-only API decisions preserve the raw album identity")
    func yearOnlyUsesRawAlbum() async throws {
        let lookupRecorder = AlbumYearLookupRecorder()
        let apiService = RecordingAlbumYearAPIService(
            lookupRecorder: lookupRecorder,
            yearResult: YearResult(
                year: 2004,
                isDefinitive: true,
                confidence: 100,
                yearScores: [2004: 100]
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
            name: "Song (Remastered 2020)",
            artist: "Clutch",
            album: "Album Remastered",
            year: nil
        )

        let changes = try await coordinator.updateTrack(
            track,
            options: UpdateOptions(
                updateGenre: true,
                updateYear: true,
                cleanTrackNames: true,
                cleanAlbumNames: true,
                minConfidence: 60
            ),
            pass: .yearOnly,
            dryRun: true
        )

        #expect(changes.map(\.changeType) == [.yearUpdate])
        #expect(changes.first?.newValue == "2004")
        let queriedAlbums = await lookupRecorder.queriedAlbums()
        #expect(!queriedAlbums.isEmpty)
        #expect(queriedAlbums.allSatisfy { $0 == "Album Remastered" })
    }

    @Test("Album type detection reads the raw title before cleaning")
    func albumTypeDetectionReadsRawTitleBeforeCleaning() async throws {
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
        var albumTypeDetection = AlbumTypeDetectionConfig()
        albumTypeDetection.specialPatterns = ["remastered"]
        albumTypeDetection.compilationPatterns = []
        albumTypeDetection.reissuePatterns = []
        let runtimeConfiguration = UpdateRuntimeConfiguration(
            policies: UpdateRuntimeConfiguration.Policies(
                isYearLookupEnabled: true,
                albumTypeDetection: albumTypeDetection
            )
        )
        let coordinator = await makeCoordinator(
            runtimeConfiguration: runtimeConfiguration,
            apiService: apiService
        )
        let track = makeTrack(
            name: "Song",
            album: "Album (Remastered)",
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

        #expect(changes.map(\.changeType) == [.albumCleaning])
        #expect(await lookupRecorder.queriedAlbums().isEmpty)
    }

    @Test("Soundtrack lookup keeps raw markers after cleaning")
    func soundtrackLookupKeepsRawMarkers() async throws {
        let lookupRecorder = AlbumYearLookupRecorder()
        let apiService = RecordingAlbumYearAPIService(
            lookupRecorder: lookupRecorder,
            yearResult: YearResult(),
            candidates: [
                ReleaseCandidate(
                    artist: "Austin Wintory",
                    album: "Journey (Original Score)",
                    year: 1968,
                    source: .musicBrainz
                ),
            ],
            candidateQueryArtist: "Journey"
        )
        var cleaning = CleaningConfig()
        cleaning.editionMarkers = ["original score"]
        var albumTypeDetection = AlbumTypeDetectionConfig()
        albumTypeDetection.soundtrackPatterns = ["original score"]
        let runtimeConfiguration = UpdateRuntimeConfiguration(
            policies: UpdateRuntimeConfiguration.Policies(
                isYearLookupEnabled: true,
                albumTypeDetection: albumTypeDetection,
                cleaning: cleaning
            )
        )
        let coordinator = await makeCoordinator(
            runtimeConfiguration: runtimeConfiguration,
            apiService: apiService
        )
        let track = makeTrack(
            name: "Nascence",
            artist: "Various Artists",
            album: "Journey (Original Score)",
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

        #expect(changes.contains { $0.changeType == .albumCleaning && $0.newValue == "Journey" })
        #expect(changes.contains { $0.changeType == .yearUpdate && $0.newValue == "1968" })
        #expect(await lookupRecorder.queriedArtists().contains("Journey"))
    }

    @Test("Rename-target exceptions do not suppress pre-rename cleaning")
    func targetExceptionKeepsCleaning() async throws {
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

        #expect(changes.map(\.changeType) == [.trackCleaning, .albumCleaning, .artistRename])
    }

    @Test("Raw-artist exceptions suppress cleaning before rename")
    func rawExceptionSkipsCleaning() async throws {
        var cleaning = CleaningConfig()
        cleaning.trackCleaningExceptions = [
            TrackCleaningException(artist: "The Beatles", album: "Album Remastered"),
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

        #expect(changes.map(\.changeType) == [.artistRename])
    }

    @Test("Cleaning precedes rename while proposals keep raw display identity")
    func cleaningKeepsRawIdentity() async throws {
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

        #expect(changes.map(\.changeType) == [.trackCleaning, .albumCleaning, .artistRename])
        #expect(changes.first { $0.changeType == .trackCleaning }?.track.artist == "The Beatles")
        #expect(changes.first { $0.changeType == .trackCleaning }?.track.name == "Song (Remastered 2020)")
        #expect(changes.first { $0.changeType == .albumCleaning }?.track.artist == "The Beatles")
        #expect(changes.first { $0.changeType == .albumCleaning }?.track.album == "Album Remastered")
    }

    @Test("Cleaned and renamed values feed downstream year decisions")
    func combinedMetadataFeedsYear() async throws {
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
            artistRenameMappings: ["The Beatles": "Beatles"],
            policies: UpdateRuntimeConfiguration.Policies(isYearLookupEnabled: true)
        )
        let coordinator = await makeCoordinator(
            runtimeConfiguration: runtimeConfiguration,
            apiService: apiService
        )
        let track = makeTrack(
            name: "Song (Remastered 2020)",
            artist: "The Beatles",
            album: "Album Remastered",
            year: nil,
            dateAdded: Date(timeIntervalSince1970: 2000)
        )

        let changes = try await coordinator.updateTrack(
            track,
            options: UpdateOptions(
                updateGenre: false,
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
            .artistRename,
            .yearUpdate,
        ])
        #expect(await lookupRecorder.queriedArtists().allSatisfy { $0 == "Beatles" })
        #expect(await lookupRecorder.queriedAlbums().allSatisfy { $0 == "Album" })
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
            dependencies: UpdateDependencies(
                apiOrchestrator: makeAPIOrchestrator(
                    musicBrainz: apiService,
                    discogs: apiService,
                    appleMusic: apiService
                ),
                scriptBridge: scriptBridge,
                stores: .init(trackStore: MockTrackStore(), cache: MockCacheService()),
                undoCoordinator: UndoCoordinator(
                    scriptBridge: scriptBridge,
                    directory: FileManager.default.temporaryDirectory
                        .appendingPathComponent("MetadataCleaningTests-\(UUID().uuidString)")
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
        year: Int? = 1969,
        dateAdded: Date? = nil
    ) -> Track {
        Track(
            id: id,
            name: name,
            artist: artist,
            album: album,
            genre: genre,
            year: year,
            dateAdded: dateAdded,
            trackStatus: nil
        )
    }
}

private actor AlbumYearLookupRecorder {
    private var albums: [String] = []
    private var artists: [String] = []

    func record(artist: String, album: String) {
        artists.append(artist)
        albums.append(album)
    }

    func queriedAlbums() -> [String] {
        albums
    }

    func queriedArtists() -> [String] {
        artists
    }
}

private struct RecordingAlbumYearAPIService: ExternalAPIService {
    let lookupRecorder: AlbumYearLookupRecorder
    let yearResult: YearResult
    var candidates: [ReleaseCandidate] = []
    var candidateQueryArtist: String?

    func getAlbumYear(
        artist: String,
        album: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        await lookupRecorder.record(artist: artist, album: album)
        return yearResult
    }

    func getReleaseCandidates(
        artist: String,
        album: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> [ReleaseCandidate] {
        await lookupRecorder.record(artist: artist, album: album)
        if let candidateQueryArtist, artist != candidateQueryArtist {
            return []
        }
        return candidates
    }

    func initialize(force _: Bool) async throws {
        try Task.checkCancellation()
    }
}
