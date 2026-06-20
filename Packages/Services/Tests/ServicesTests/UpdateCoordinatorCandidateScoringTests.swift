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

    @Test("Allows mapped target track when album context has unmapped tracks")
    func allowsMappedTargetTrackWhenAlbumContextHasUnmappedTracks() async throws {
        let mappedMusicKitTrack = Track(
            id: "MK-1",
            name: "Sugar Creek",
            artist: "SubRosa",
            album: "Strega",
            year: nil,
            releaseYear: 2008
        )
        let unmappedMusicKitTrack = Track(
            id: "MK-2",
            name: "Crucible",
            artist: "SubRosa",
            album: "Strega",
            year: nil,
            releaseYear: 2008
        )
        let mappedAppleScriptTrack = Track(
            id: "AS-1",
            name: "Sugar Creek",
            artist: "SubRosa",
            album: "Strega",
            year: 2211,
            trackStatus: "subscription",
            releaseYear: 2008,
            albumArtist: "SubRosa"
        )
        let mapper = TrackIDMapper()
        await mapper.refreshMapping(
            musicKitTracks: [mappedMusicKitTrack, unmappedMusicKitTrack],
            appleScriptTracks: [mappedAppleScriptTrack]
        )
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        let api = makeAPIOrchestrator(
            musicBrainz: MockAPIService(),
            discogs: MockAPIService(),
            appleMusic: MockAPIService()
        )
        let coordinator = makeCoordinator(api: api, bridge: bridge, cache: cache, idMapper: mapper)

        let changes = try await coordinator.updateTrack(
            mappedMusicKitTrack,
            albumTracks: [mappedMusicKitTrack, unmappedMusicKitTrack],
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        let yearChange = try #require(changes.first { $0.changeType == ChangeType.yearUpdate })
        #expect(yearChange.oldValue == "2211")
        #expect(yearChange.newValue == "2008")
        #expect(yearChange.source == "Consensus")
    }

    @Test("Does not rewrite valid editable year from release year without API confirmation")
    func doesNotRewriteValidEditableYearWithoutAPIConfirmation() async throws {
        let track = Track(
            id: "subrosa-1",
            name: "Sugar Creek",
            artist: "SubRosa",
            album: "Strega",
            year: 2023,
            releaseYear: 2008
        )
        let albumTracks = [
            track,
            Track(
                id: "subrosa-2",
                name: "Crucible",
                artist: "SubRosa",
                album: "Strega",
                year: 2023,
                releaseYear: 2008
            ),
        ]
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
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

        #expect(!changes.contains { $0.changeType == ChangeType.yearUpdate })
    }

    @Test("Uses API confirmation when release year conflicts with valid editable year")
    func usesAPIConfirmationForConflictingReleaseYear() async throws {
        let track = Track(
            id: "subrosa-1",
            name: "Sugar Creek",
            artist: "SubRosa",
            album: "Strega",
            year: 2023,
            releaseYear: 2008
        )
        let albumTracks = [
            track,
            Track(
                id: "subrosa-2",
                name: "Crucible",
                artist: "SubRosa",
                album: "Strega",
                year: 2023,
                releaseYear: 2008
            ),
        ]
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        let api = makeAPIOrchestrator(
            musicBrainz: MockAPIService(releaseCandidates: [
                ReleaseCandidate(
                    artist: "SubRosa",
                    album: "Strega",
                    year: 2008,
                    source: .musicBrainz,
                    mbReleaseGroupFirstYear: 2008
                ),
            ]),
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
        #expect(yearChange.oldValue == "2023")
        #expect(yearChange.newValue == "2008")
        #expect(yearChange.source == "Api")
    }

    @Test("Uses cached year when it matches the release year conflict target")
    func usesCachedYearWhenItMatchesTheReleaseYearConflictTarget() async throws {
        let track = Track(
            id: "subrosa-1",
            name: "Sugar Creek",
            artist: "SubRosa",
            album: "Strega",
            year: 2023,
            releaseYear: 2008
        )
        let albumTracks = [
            track,
            Track(
                id: "subrosa-2",
                name: "Crucible",
                artist: "SubRosa",
                album: "Strega",
                year: 2023,
                releaseYear: 2008
            ),
        ]
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        await cache.storeAlbumYear(
            artist: "SubRosa",
            album: "Strega",
            year: 2008,
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
        #expect(yearChange.oldValue == "2023")
        #expect(yearChange.newValue == "2008")
        #expect(yearChange.source == "Cache")
    }

    @Test("Falls back to API when cached year does not match the release year conflict target")
    func fallsBackToAPIWhenCachedYearDoesNotMatchTheReleaseYearConflictTarget() async throws {
        let track = Track(
            id: "subrosa-1",
            name: "Sugar Creek",
            artist: "SubRosa",
            album: "Strega",
            year: 2023,
            releaseYear: 2008
        )
        let albumTracks = [
            track,
            Track(
                id: "subrosa-2",
                name: "Crucible",
                artist: "SubRosa",
                album: "Strega",
                year: 2023,
                releaseYear: 2008
            ),
        ]
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        await cache.storeAlbumYear(
            artist: "SubRosa",
            album: "Strega",
            year: 2010,
            confidence: 100
        )
        let api = makeAPIOrchestrator(
            musicBrainz: MockAPIService(releaseCandidates: [
                ReleaseCandidate(
                    artist: "SubRosa",
                    album: "Strega",
                    year: 2008,
                    source: .musicBrainz,
                    mbReleaseGroupFirstYear: 2008
                ),
            ]),
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
        #expect(yearChange.oldValue == "2023")
        #expect(yearChange.newValue == "2008")
        #expect(yearChange.source == "Api")
    }

    @Test("Uses API confirmation when only the target track has a valid release year signal")
    func usesAPIConfirmationWhenOnlyTheTargetTrackHasAValidReleaseYearSignal() async throws {
        let track = Track(
            id: "subrosa-1",
            name: "Sugar Creek",
            artist: "SubRosa",
            album: "Strega",
            year: 2023,
            releaseYear: 2008
        )
        let albumTracks = [
            track,
            Track(
                id: "subrosa-2",
                name: "Crucible",
                artist: "SubRosa",
                album: "Strega",
                year: 2023,
                releaseYear: nil
            ),
        ]
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        let api = makeAPIOrchestrator(
            musicBrainz: MockAPIService(releaseCandidates: [
                ReleaseCandidate(
                    artist: "SubRosa",
                    album: "Strega",
                    year: 2008,
                    source: .musicBrainz,
                    mbReleaseGroupFirstYear: 2008
                ),
            ]),
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
        #expect(yearChange.oldValue == "2023")
        #expect(yearChange.newValue == "2008")
        #expect(yearChange.source == "Api")
    }

    @Test("Does not write when API conflicts with release year signal")
    func doesNotWriteWhenAPIConflictsWithReleaseYearSignal() async throws {
        let track = Track(
            id: "subrosa-1",
            name: "Sugar Creek",
            artist: "SubRosa",
            album: "Strega",
            year: 2023,
            releaseYear: 2008
        )
        let albumTracks = [
            track,
            Track(
                id: "subrosa-2",
                name: "Crucible",
                artist: "SubRosa",
                album: "Strega",
                year: 2023,
                releaseYear: 2008
            ),
        ]
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        let api = makeAPIOrchestrator(
            musicBrainz: MockAPIService(releaseCandidates: [
                ReleaseCandidate(
                    artist: "SubRosa",
                    album: "Strega",
                    year: 2010,
                    source: .musicBrainz,
                    mbReleaseGroupFirstYear: 2010
                ),
            ]),
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

        #expect(!changes.contains { $0.changeType == ChangeType.yearUpdate })
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
