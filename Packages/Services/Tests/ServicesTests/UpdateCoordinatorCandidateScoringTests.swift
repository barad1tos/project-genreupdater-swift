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
        let track = subRosaTrack()
        let albumTracks = subRosaAlbumTracks()
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        let api = emptyAPIOrchestrator()
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
        let track = subRosaTrack()
        let albumTracks = subRosaAlbumTracks()
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        let api = subRosaAPIOrchestrator(confirmingYear: 2008)
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
        let track = subRosaTrack()
        let albumTracks = subRosaAlbumTracks()
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        await cache.storeAlbumYear(
            artist: "SubRosa",
            album: "Strega",
            year: 2008,
            confidence: 100
        )
        let api = emptyAPIOrchestrator()
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

    @Test("Skips year lookup when cached year matches the library")
    func skipsYearLookupWhenCachedYearMatchesTheLibrary() async throws {
        let track = subRosaTrack(year: 2008)
        let albumTracks = subRosaAlbumTracks(year: 2008)
        let fixture = makeProbedCoordinator()
        await fixture.cache.storeAlbumYear(
            artist: "SubRosa",
            album: "Strega",
            year: 2008,
            confidence: 100
        )

        let changes = try await fixture.coordinator.updateTrack(
            track,
            albumTracks: albumTracks,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        #expect(!changes.contains { $0.changeType == ChangeType.yearUpdate })
        #expect(await fixture.apiProbe.requestCount == 0)
    }

    @Test("Skips year lookup for recent fallback rejections")
    func skipsYearLookupForRecentFallbackRejections() async throws {
        let track = subRosaTrack(year: 2008)
        let albumTracks = subRosaAlbumTracks(year: 2008)
        let pendingVerification = PendingVerificationProbe(
            entry: pendingFallbackRejection(reason: "suspicious_year_change"),
            isVerificationNeeded: false
        )
        let fixture = makeProbedCoordinator(
            pendingVerificationService: pendingVerification
        )

        let changes = try await fixture.coordinator.updateTrack(
            track,
            albumTracks: albumTracks,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        #expect(!changes.contains { $0.changeType == ChangeType.yearUpdate })
        #expect(await fixture.apiProbe.requestCount == 0)
    }

    @Test("Does not skip year lookup when fallback rejection is due")
    func doesNotSkipYearLookupWhenFallbackRejectionIsDue() async throws {
        let track = subRosaTrack(year: 2008, releaseYear: 1999)
        let albumTracks = [
            track,
            subRosaTrack(id: "subrosa-2", name: "Crucible", year: 2008, releaseYear: 1999),
        ]
        let pendingVerification = PendingVerificationProbe(
            entry: pendingFallbackRejection(reason: "suspicious_year_change"),
            isVerificationNeeded: true
        )
        let fixture = makeProbedCoordinator(
            pendingVerificationService: pendingVerification
        )

        _ = try await fixture.coordinator.updateTrack(
            track,
            albumTracks: albumTracks,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        #expect(await fixture.apiProbe.requestCount > 0)
    }

    @Test("Skips API lookup when uncached album years are consistently valid")
    func skipsAPILookupWhenUncachedAlbumYearsAreConsistentlyValid() async throws {
        let track = subRosaTrack(year: 2008, releaseYear: nil)
        let albumTracks = [
            track,
            subRosaTrack(id: "subrosa-2", name: "Crucible", year: 2008, releaseYear: nil),
        ]
        let fixture = makeProbedCoordinator()

        let changes = try await fixture.coordinator.updateTrack(
            track,
            albumTracks: albumTracks,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        #expect(!changes.contains { $0.changeType == ChangeType.yearUpdate })
        #expect(await fixture.apiProbe.requestCount == 0)
    }

    @Test("Uses API verification for recent uncached years without release year")
    func usesAPIVerificationForRecentUncachedYearsWithoutReleaseYear() async throws {
        let currentYear = Calendar.current.component(.year, from: Date())
        let track = subRosaTrack(year: currentYear, releaseYear: nil)
        let albumTracks = [
            track,
            subRosaTrack(id: "subrosa-2", name: "Crucible", year: currentYear, releaseYear: nil),
        ]
        let fixture = makeProbedCoordinator()

        _ = try await fixture.coordinator.updateTrack(
            track,
            albumTracks: albumTracks,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        #expect(await fixture.apiProbe.requestCount > 0)
    }

    @Test("Skips year lookup when every album track was already processed")
    func skipsYearLookupWhenEveryAlbumTrackWasAlreadyProcessed() async throws {
        let track = subRosaTrack(year: 2008, yearSetByMGU: 2008)
        let albumTracks = subRosaAlbumTracks(year: 2008, yearSetByMGU: 2008)
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        await cache.storeAlbumYear(
            artist: "SubRosa",
            album: "Strega",
            year: 1999,
            confidence: 100
        )
        let api = subRosaAPIOrchestrator(confirmingYear: 1999)
        let coordinator = makeCoordinator(api: api, bridge: bridge, cache: cache)

        let changes = try await coordinator.updateTrack(
            track,
            albumTracks: albumTracks,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        #expect(!changes.contains { $0.changeType == ChangeType.yearUpdate })
    }

    @Test("Force year lookup bypasses already processed album skip")
    func forceYearLookupBypassesAlreadyProcessedAlbumSkip() async throws {
        let track = subRosaTrack(year: 2008, yearSetByMGU: 2008)
        let albumTracks = subRosaAlbumTracks(year: 2008, yearSetByMGU: 2008)
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        await cache.storeAlbumYear(
            artist: "SubRosa",
            album: "Strega",
            year: 2008,
            confidence: 100
        )
        let api = subRosaAPIOrchestrator(confirmingYear: 1999)
        let coordinator = makeCoordinator(api: api, bridge: bridge, cache: cache)

        let changes = try await coordinator.updateTrack(
            track,
            albumTracks: albumTracks,
            options: UpdateOptions(updateGenre: false, updateYear: true, forceYearLookup: true),
            dryRun: true
        )

        let yearChange = try #require(changes.first { $0.changeType == ChangeType.yearUpdate })
        #expect(yearChange.oldValue == "2008")
        #expect(yearChange.newValue == "1999")
        #expect(yearChange.source == "Api")
    }

    @Test("Force lookup trusts fresh release year over stale API")
    func forceLookupTrustsFreshReleaseYearOverStaleAPI() async throws {
        let currentYear = Calendar.current.component(.year, from: Date())
        let staleAPIYear = currentYear - 2
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
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        let api = makeAPIOrchestrator(
            musicBrainz: MockAPIService(yearResult: YearResult(
                year: staleAPIYear,
                isDefinitive: false,
                confidence: 100,
                yearScores: [staleAPIYear: 100]
            )),
            discogs: MockAPIService(),
            appleMusic: MockAPIService()
        )
        let pendingVerification = PendingVerificationProbe(entry: nil, isVerificationNeeded: true)
        let coordinator = makeCoordinator(
            api: api,
            bridge: bridge,
            cache: cache,
            pendingVerificationService: pendingVerification
        )

        let changes = try await coordinator.updateTrack(
            track,
            albumTracks: albumTracks,
            options: UpdateOptions(updateGenre: false, updateYear: true, forceYearLookup: true),
            dryRun: true
        )

        let yearChange = try #require(changes.first { $0.changeType == ChangeType.yearUpdate })
        #expect(yearChange.oldValue == nil)
        #expect(yearChange.newValue == String(currentYear))
        #expect(yearChange.source == "Release Year")

        let markedAlbums = await pendingVerification.markedAlbums
        let markedAlbum = try #require(markedAlbums.first)
        #expect(markedAlbums.count == 1)
        #expect(markedAlbum.reason == "stale_api_data_for_fresh_album")
        #expect(markedAlbum.metadata["release_year"] == String(currentYear))
        #expect(markedAlbum.metadata["proposed_year"] == String(staleAPIYear))
    }

    @Test("Does not skip year lookup for partially processed albums")
    func doesNotSkipYearLookupForPartiallyProcessedAlbums() async throws {
        let track = subRosaTrack(year: 2008, yearSetByMGU: 2008)
        let albumTracks = [
            track,
            subRosaTrack(
                id: "subrosa-2",
                name: "Crucible",
                year: 2008,
                releaseYear: 2008
            ),
        ]
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        await cache.storeAlbumYear(
            artist: "SubRosa",
            album: "Strega",
            year: 1999,
            confidence: 100
        )
        let api = subRosaAPIOrchestrator(confirmingYear: 1999)
        let coordinator = makeCoordinator(api: api, bridge: bridge, cache: cache)

        let changes = try await coordinator.updateTrack(
            track,
            albumTracks: albumTracks,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        let yearChange = try #require(changes.first { $0.changeType == ChangeType.yearUpdate })
        #expect(yearChange.oldValue == "2008")
        #expect(yearChange.newValue == "1999")
    }

    @Test("Falls back to API when cached year does not match the release year conflict target")
    func fallsBackToAPIWhenCachedYearDoesNotMatchTheReleaseYearConflictTarget() async throws {
        let track = subRosaTrack()
        let albumTracks = subRosaAlbumTracks()
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        await cache.storeAlbumYear(
            artist: "SubRosa",
            album: "Strega",
            year: 2010,
            confidence: 100
        )
        let api = subRosaAPIOrchestrator(confirmingYear: 2008)
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
        let track = subRosaTrack()
        let albumTracks = subRosaAlbumTracks(secondReleaseYear: nil)
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        let api = subRosaAPIOrchestrator(confirmingYear: 2008)
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

    @Test("Does not rewrite when only target release year signal lacks confirmation")
    func doesNotRewriteWhenOnlyTargetReleaseYearSignalLacksConfirmation() async throws {
        let track = subRosaTrack()
        let albumTracks = subRosaAlbumTracks(secondReleaseYear: nil)
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        let api = emptyAPIOrchestrator()
        let coordinator = makeCoordinator(api: api, bridge: bridge, cache: cache)

        let changes = try await coordinator.updateTrack(
            track,
            albumTracks: albumTracks,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: false
        )
        let written = await bridge.writtenProperties

        #expect(!changes.contains { $0.changeType == ChangeType.yearUpdate })
        #expect(written.isEmpty)
    }

    @Test("Does not rewrite when cache conflicts with release year and APIs do not confirm")
    func doesNotRewriteWhenCacheConflictsWithReleaseYearAndAPIsDoNotConfirm() async throws {
        let track = subRosaTrack()
        let albumTracks = subRosaAlbumTracks()
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        await cache.storeAlbumYear(
            artist: "SubRosa",
            album: "Strega",
            year: 2010,
            confidence: 100
        )
        let api = emptyAPIOrchestrator()
        let coordinator = makeCoordinator(api: api, bridge: bridge, cache: cache)

        let changes = try await coordinator.updateTrack(
            track,
            albumTracks: albumTracks,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: false
        )
        let written = await bridge.writtenProperties

        #expect(!changes.contains { $0.changeType == ChangeType.yearUpdate })
        #expect(written.isEmpty)
    }

    @Test("Does not write when API conflicts with release year signal")
    func doesNotWriteWhenAPIConflictsWithReleaseYearSignal() async throws {
        let track = subRosaTrack()
        let albumTracks = subRosaAlbumTracks()
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        let api = subRosaAPIOrchestrator(confirmingYear: 2010)
        let coordinator = makeCoordinator(api: api, bridge: bridge, cache: cache)

        let changes = try await coordinator.updateTrack(
            track,
            albumTracks: albumTracks,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        #expect(!changes.contains { $0.changeType == ChangeType.yearUpdate })
    }

    @Test("Uses API confirmation when album release years disagree")
    func usesAPIConfirmationWhenAlbumReleaseYearsDisagree() async throws {
        let track = subRosaTrack()
        let albumTracks = [
            track,
            subRosaTrack(
                id: "subrosa-2",
                name: "Crucible",
                releaseYear: 2010
            ),
        ]
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        let api = subRosaAPIOrchestrator(confirmingYear: 2010)
        let coordinator = makeCoordinator(api: api, bridge: bridge, cache: cache)

        let changes = try await coordinator.updateTrack(
            track,
            albumTracks: albumTracks,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        let yearChange = try #require(changes.first { $0.changeType == ChangeType.yearUpdate })
        #expect(yearChange.oldValue == "2023")
        #expect(yearChange.newValue == "2010")
        #expect(yearChange.source == "Api")
    }

    private func subRosaTrack(
        id: String = "subrosa-1",
        name: String = "Sugar Creek",
        year: Int? = 2023,
        releaseYear: Int? = 2008,
        yearSetByMGU: Int? = nil
    ) -> Track {
        Track(
            id: id,
            name: name,
            artist: "SubRosa",
            album: "Strega",
            year: year,
            yearSetByMGU: yearSetByMGU,
            releaseYear: releaseYear
        )
    }

    private func subRosaAlbumTracks(
        secondReleaseYear: Int? = 2008,
        year: Int? = 2023,
        yearSetByMGU: Int? = nil
    ) -> [Track] {
        [
            subRosaTrack(year: year, yearSetByMGU: yearSetByMGU),
            subRosaTrack(
                id: "subrosa-2",
                name: "Crucible",
                year: year,
                releaseYear: secondReleaseYear,
                yearSetByMGU: yearSetByMGU
            ),
        ]
    }

    private func subRosaAPIOrchestrator(confirmingYear year: Int) -> APIOrchestrator {
        makeAPIOrchestrator(
            musicBrainz: MockAPIService(releaseCandidates: [
                ReleaseCandidate(
                    artist: "SubRosa",
                    album: "Strega",
                    year: year,
                    source: .musicBrainz,
                    mbReleaseGroupFirstYear: year
                ),
            ]),
            discogs: MockAPIService(),
            appleMusic: MockAPIService()
        )
    }

    private func emptyAPIOrchestrator() -> APIOrchestrator {
        makeAPIOrchestrator(
            musicBrainz: MockAPIService(),
            discogs: MockAPIService(),
            appleMusic: MockAPIService()
        )
    }

    private func makeProbedCoordinator(
        definitiveYear year: Int = 1999,
        pendingVerificationService: (any PendingVerificationService)? = nil
    ) -> (
        cache: MockCacheService,
        apiProbe: APIRequestProbe,
        coordinator: UpdateCoordinator
    ) {
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        let apiProbe = APIRequestProbe()
        let api = makeAPIOrchestrator(
            musicBrainz: UpdateCoordinatorRecordingAPIService(probe: apiProbe, yearResult: YearResult(
                year: year,
                isDefinitive: true,
                confidence: 100
            )),
            discogs: UpdateCoordinatorRecordingAPIService(probe: apiProbe),
            appleMusic: UpdateCoordinatorRecordingAPIService(probe: apiProbe)
        )
        let coordinator = makeCoordinator(
            api: api,
            bridge: bridge,
            cache: cache,
            pendingVerificationService: pendingVerificationService
        )
        return (cache, apiProbe, coordinator)
    }

    private func pendingFallbackRejection(reason: String) -> PendingAlbumEntry {
        PendingAlbumEntry(
            id: "subrosa-strega",
            artist: "SubRosa",
            album: "Strega",
            reason: reason,
            attemptCount: 1,
            lastAttempt: Date(),
            recheckInterval: 30 * 24 * 60 * 60
        )
    }

    private func makeCoordinator(
        api: APIOrchestrator,
        bridge: MockAppleScriptClient,
        cache: MockCacheService,
        idMapper: (any TrackIDMapping)? = nil,
        pendingVerificationService: (any PendingVerificationService)? = nil
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
                idMapper: idMapper,
                librarySnapshotService: nil,
                pendingVerificationService: pendingVerificationService
            ),
            genreDeterminator: GenreDeterminator(),
            yearDeterminator: YearDeterminator()
        )
    }
}
