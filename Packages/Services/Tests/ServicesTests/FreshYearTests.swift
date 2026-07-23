import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("UpdateCoordinator - Fresh release years")
struct FreshYearTests {
    private struct FreshYearFixture {
        let track: Track
        let albumTracks: [Track]
        let pendingVerification: PendingVerificationProbe
        let coordinator: UpdateCoordinator
    }

    @Test("Force lookup trusts fresh release year over stale API")
    func forceLookupTrustsFreshReleaseYearOverStaleAPI() async throws {
        let currentYear = Calendar.current.component(.year, from: Date())
        let staleAPIYear = currentYear - 2
        let fixture = makeFixture(currentYear: currentYear, staleAPIYear: staleAPIYear)

        let changes = try await fixture.coordinator.updateTrack(
            fixture.track,
            albumTracks: fixture.albumTracks,
            options: UpdateOptions(updateGenre: false, updateYear: true, forceYearLookup: true),
            dryRun: true
        )

        let yearChange = try #require(changes.first { $0.changeType == ChangeType.yearUpdate })
        #expect(yearChange.oldValue == nil)
        #expect(yearChange.newValue == String(currentYear))
        #expect(yearChange.source == "Release Year")

        let markedAlbums = await fixture.pendingVerification.markedAlbums
        let markedAlbum = try #require(markedAlbums.first)
        #expect(markedAlbums.count == 1)
        #expect(markedAlbum.reason == "stale_api_data_for_fresh_album")
        #expect(markedAlbum.metadata["release_year"] == String(currentYear))
        #expect(markedAlbum.metadata["proposed_year"] == String(staleAPIYear))
    }

    @Test("Force lookup keeps definitive stale API over fresh release year")
    func forceLookupKeepsDefinitiveStaleAPIOverFreshReleaseYear() async throws {
        let currentYear = Calendar.current.component(.year, from: Date())
        let staleAPIYear = currentYear - 2
        let fixture = makeFixture(
            currentYear: currentYear,
            staleAPIYear: staleAPIYear,
            isDefinitive: true
        )

        let changes = try await fixture.coordinator.updateTrack(
            fixture.track,
            albumTracks: fixture.albumTracks,
            options: UpdateOptions(updateGenre: false, updateYear: true, forceYearLookup: true),
            dryRun: true
        )

        let yearChange = try #require(changes.first { $0.changeType == ChangeType.yearUpdate })
        #expect(yearChange.oldValue == nil)
        #expect(yearChange.newValue == String(staleAPIYear))
        #expect(yearChange.source == "Definitive")
        #expect(await fixture.pendingVerification.markedAlbums.isEmpty)
    }

    private func makeFixture(
        currentYear: Int,
        staleAPIYear: Int,
        isDefinitive: Bool = false
    ) -> FreshYearFixture {
        let track = subRosaTrack(year: nil, releaseYear: currentYear)
        let albumTracks = [
            track,
            subRosaTrack(
                id: "subrosa-2",
                name: "Crucible",
                year: nil,
                releaseYear: currentYear
            ),
        ]
        let pendingVerification = PendingVerificationProbe(entry: nil, isVerificationNeeded: true)
        let coordinator = makeCoordinator(
            api: makeAPI(staleAPIYear: staleAPIYear, isDefinitive: isDefinitive),
            bridge: MockAppleScriptClient(),
            cache: MockCacheService(),
            pendingVerificationService: pendingVerification
        )
        return FreshYearFixture(
            track: track,
            albumTracks: albumTracks,
            pendingVerification: pendingVerification,
            coordinator: coordinator
        )
    }

    private func subRosaTrack(
        id: String = "subrosa-1",
        name: String = "Sugar Creek",
        year: Int?,
        releaseYear: Int
    ) -> Track {
        Track(
            id: id,
            name: name,
            artist: "SubRosa",
            album: "Strega",
            year: year,
            releaseYear: releaseYear
        )
    }

    private func makeAPI(staleAPIYear: Int, isDefinitive: Bool) -> APIOrchestrator {
        let staleYearResult = YearResult(
            year: staleAPIYear,
            isDefinitive: isDefinitive,
            confidence: 100,
            yearScores: [staleAPIYear: 100]
        )
        return makeAPIOrchestrator(
            musicBrainz: MockAPIService(yearResult: staleYearResult),
            discogs: MockAPIService(yearResult: isDefinitive ? staleYearResult : YearResult()),
            appleMusic: MockAPIService()
        )
    }

    private func makeCoordinator(
        api: APIOrchestrator,
        bridge: MockAppleScriptClient,
        cache: MockCacheService,
        pendingVerificationService: any PendingVerificationService
    ) -> UpdateCoordinator {
        let undoDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FreshYearTests-\(UUID().uuidString)")
        return UpdateCoordinator(
            dependencies: UpdateDependencies(
                apiOrchestrator: api,
                scriptBridge: bridge,
                stores: .init(
                    trackStore: MockTrackStore(),
                    cache: cache
                ),
                undoCoordinator: UndoCoordinator(
                    scriptBridge: bridge,
                    directory: undoDirectory
                ),
                librarySnapshotService: nil,
                pendingVerificationService: pendingVerificationService
            ),
            genreDeterminator: GenreDeterminator(),
            yearDeterminator: YearDeterminator()
        )
    }
}
