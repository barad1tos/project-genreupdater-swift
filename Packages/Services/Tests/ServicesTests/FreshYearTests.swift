import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("UpdateCoordinator - Fresh release years")
struct FreshYearTests {
    private struct FreshYearFixture {
        let track: Track
        let albumTracks: [Track]
        let cache: MockCacheService
        let pendingVerification: PendingVerificationProbe
        let coordinator: UpdateCoordinator
    }

    @Test("Force lookup trusts fresh release year over stale API")
    func prefersReleaseYear() async throws {
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
        let markedAlbum = try #require(markedAlbums.last)
        #expect(markedAlbums.count == 2)
        #expect(markedAlbums.allSatisfy { $0.reason == "no_year_found" })
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

    @Test("Confirmed API miss marks an album for verification")
    func confirmedMissMarksPending() async throws {
        for existingYear in [nil, 1999] as [Int?] {
            let fixture = makeMissingYearFixture(
                year: existingYear,
                musicBrainz: MockAPIService()
            )

            let changes = try await fixture.coordinator.updateTrack(
                fixture.track,
                albumTracks: fixture.albumTracks,
                options: UpdateOptions(updateGenre: false, updateYear: true, forceYearLookup: true),
                dryRun: true
            )

            #expect(changes.allSatisfy { $0.changeType != .yearUpdate })
            let markedAlbums = await fixture.pendingVerification.markedAlbums
            #expect(markedAlbums.count == 1)
            #expect(markedAlbums.first?.reason == "no_year_found")
        }
    }

    @Test("Failed API lookup does not mark a missing-year album for verification")
    func failedLookupSkipsMark() async throws {
        let fixture = makeMissingYearFixture(musicBrainz: MockAPIService(shouldThrow: true))

        let changes = try await fixture.coordinator.updateTrack(
            fixture.track,
            albumTracks: fixture.albumTracks,
            options: UpdateOptions(updateGenre: false, updateYear: true, forceYearLookup: true),
            dryRun: true
        )

        #expect(changes.allSatisfy { $0.changeType != .yearUpdate })
        #expect(await fixture.pendingVerification.markedAlbums.isEmpty)
    }

    @Test("Partial provider failure does not become a confirmed miss")
    func partialFailureSkipsMark() async throws {
        let fixture = makeMissingYearFixture(
            musicBrainz: MockAPIService(),
            discogs: MockAPIService(shouldThrow: true),
            appleMusic: MockAPIService(shouldThrow: true)
        )

        let changes = try await fixture.coordinator.updateTrack(
            fixture.track,
            albumTracks: fixture.albumTracks,
            options: UpdateOptions(updateGenre: false, updateYear: true, forceYearLookup: true),
            dryRun: true
        )

        #expect(changes.allSatisfy { $0.changeType != .yearUpdate })
        #expect(await fixture.pendingVerification.markedAlbums.isEmpty)
        #expect(await fixture.cache.getAlbumYear(artist: "Artist", album: "Album") == nil)
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
        let cache = MockCacheService()
        let coordinator = makeCoordinator(
            api: makeAPI(staleAPIYear: staleAPIYear, isDefinitive: isDefinitive),
            bridge: MockAppleScriptClient(),
            cache: cache,
            pendingVerificationService: pendingVerification
        )
        return FreshYearFixture(
            track: track,
            albumTracks: albumTracks,
            cache: cache,
            pendingVerification: pendingVerification,
            coordinator: coordinator
        )
    }

    private func makeMissingYearFixture(
        year: Int? = nil,
        musicBrainz: any ExternalAPIService,
        discogs: (any ExternalAPIService)? = nil,
        appleMusic: (any ExternalAPIService)? = nil
    ) -> FreshYearFixture {
        let track = Track(
            id: "missing-year-1",
            name: "Missing Year",
            artist: "Artist",
            album: "Album",
            year: year
        )
        let pendingVerification = PendingVerificationProbe(entry: nil, isVerificationNeeded: true)
        let cache = MockCacheService()
        let coordinator = makeCoordinator(
            api: makeAPIOrchestrator(
                musicBrainz: musicBrainz,
                discogs: discogs ?? musicBrainz,
                appleMusic: appleMusic ?? musicBrainz
            ),
            bridge: MockAppleScriptClient(),
            cache: cache,
            pendingVerificationService: pendingVerification
        )
        return FreshYearFixture(
            track: track,
            albumTracks: [track],
            cache: cache,
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
