import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("UpdateCoordinator - API release candidate scoring")
struct UpdateCoordinatorCandidateScoringTests {
    @Test("uses API release candidates when legacy YearResult is empty")
    func usesAPIReleaseCandidatesWhenLegacyResultIsEmpty() async throws {
        let track = Track(
            id: "track-1",
            name: "Opening Track",
            artist: "Test Artist",
            album: "Test Album",
            year: nil,
            trackStatus: nil
        )
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        let api = makeAPIOrchestrator(
            musicBrainz: MockAPIService(releaseCandidates: [
                ReleaseCandidate(
                    artist: "Test Artist",
                    album: "Test Album",
                    year: 1998,
                    source: .musicBrainz,
                    mbReleaseGroupFirstYear: 1998
                ),
            ]),
            discogs: MockAPIService(),
            appleMusic: MockAPIService()
        )
        let coordinator = makeCoordinator(api: api, bridge: bridge, cache: cache)

        let changes = try await coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        let yearChange = try #require(changes.first { $0.changeType == .yearUpdate })
        #expect(yearChange.newValue == "1998")
        #expect(yearChange.source != "API")
    }

    @Test("Uses AppleScript editable year when scoring MusicKit tracks")
    func usesAppleScriptEditableYearWhenScoringMusicKitTracks() async throws {
        let musicKitTrack = Track(
            id: "MK1",
            name: "Foregone Pt. 1",
            artist: "In Flames",
            album: "Foregone",
            year: nil,
            trackStatus: nil,
            releaseYear: 2023
        )
        let appleScriptTrack = Track(
            id: "AS-HEX-1",
            name: "Foregone Pt. 1",
            artist: "In Flames",
            album: "Foregone",
            year: 2021,
            trackStatus: "subscription",
            releaseYear: 2023,
            albumArtist: "In Flames"
        )
        let mapper = TrackIDMapper()
        await mapper.refreshMapping(
            musicKitTracks: [musicKitTrack],
            appleScriptTracks: [appleScriptTrack]
        )
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        let api = APIOrchestrator(
            musicBrainz: MockAPIService(releaseCandidates: [
                ReleaseCandidate(
                    artist: "In Flames",
                    album: "Foregone",
                    year: 2023,
                    source: .musicBrainz,
                    mbReleaseGroupFirstYear: 2023
                ),
            ]),
            discogs: MockAPIService(),
            appleMusic: MockAPIService()
        )
        let coordinator = makeCoordinator(api: api, bridge: bridge, cache: cache, idMapper: mapper)

        let changes = try await coordinator.updateTrack(
            musicKitTrack,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        let yearChange = try #require(changes.first { $0.changeType == ChangeType.yearUpdate })
        #expect(yearChange.oldValue == "2021")
        #expect(yearChange.newValue == "2023")
    }

    @Test("Repairs invalid editable year from release year before trusting cache")
    func repairsInvalidEditableYearBeforeTrustingCache() async throws {
        let track = Track(
            id: "clutch-1",
            name: "The Elephant Riders",
            artist: "Clutch",
            album: "The Elephant Riders",
            year: 2211,
            releaseYear: 1998
        )
        let albumTracks = [
            track,
            Track(
                id: "clutch-2",
                name: "Ship of Gold",
                artist: "Clutch",
                album: "The Elephant Riders",
                year: 2211,
                releaseYear: 1998
            ),
        ]
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        await cache.storeAlbumYear(
            artist: "Clutch",
            album: "The Elephant Riders",
            year: 2004,
            confidence: 100
        )
        let api = makeAPIOrchestrator(
            musicBrainz: MockAPIService(),
            discogs: MockAPIService(),
            appleMusic: MockAPIService()
        )
        let coordinator = makeCoordinator(api: api, bridge: bridge, cache: cache)

        let changes = try await coordinator.updateTrack(
            track,
            albumTracks: albumTracks,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        let yearChange = try #require(changes.first { $0.changeType == ChangeType.yearUpdate })
        #expect(yearChange.oldValue == "2211")
        #expect(yearChange.newValue == "1998")
        #expect(yearChange.source == "Consensus")
    }

    private func makeCoordinator(
        api: APIOrchestrator,
        bridge: MockAppleScriptClient,
        cache: MockCacheService,
        idMapper: (any TrackIDMapping)? = nil
    ) -> UpdateCoordinator {
        let undoDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateCoordinatorCandidateScoringTests-\(UUID().uuidString)")
        return UpdateCoordinator(
            dependencies: UpdateCoordinatorDependencies(
                apiOrchestrator: api,
                scriptBridge: bridge,
                trackStore: MockTrackStore(),
                cache: cache,
                undoCoordinator: UndoCoordinator(scriptBridge: bridge, directory: undoDirectory),
                idMapper: idMapper
            ),
            genreDeterminator: GenreDeterminator(),
            yearDeterminator: YearDeterminator()
        )
    }
}
