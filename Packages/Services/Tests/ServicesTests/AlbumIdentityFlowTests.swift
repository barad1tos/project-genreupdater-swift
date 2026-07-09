import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("UpdateCoordinator album identity")
struct AlbumIdentityFlowTests {
    @Test("Year API lookup uses album identity artist")
    func yearAPILookupUsesAlbumIdentityArtist() async throws {
        let apiProbe = APIRequestProbe()
        let apiService = UpdateAPIDouble(
            probe: apiProbe,
            yearResult: YearResult(
                year: 2013,
                isDefinitive: true,
                confidence: 100,
                yearScores: [2013: 100]
            )
        )
        let coordinator = makeCoordinator(apiService: apiService)
        let track = makeTrack(
            id: "ram-1",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            year: 2012
        )

        _ = try await coordinator.updateTrack(
            track,
            albumTracks: [track],
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        let requests = await apiProbe.albumRequests
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { $0.artist == "Daft Punk" })
        #expect(requests.allSatisfy { $0.album == "Random Access Memories" })
    }

    @Test("Candidate scoring uses album identity artist activity period")
    func candidateScoringUsesAlbumIdentityArtistActivityPeriod() async throws {
        let apiProbe = APIRequestProbe()
        let apiService = UpdateAPIDouble(
            probe: apiProbe,
            releaseCandidates: [
                ReleaseCandidate(
                    artist: "Daft Punk",
                    album: "Random Access Memories",
                    year: 2013,
                    source: .musicBrainz
                ),
            ]
        )
        let coordinator = makeCoordinator(apiService: apiService)
        let track = makeTrack(
            id: "ram-activity",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            year: 2012,
            metadata: .init(albumArtist: "Daft Punk")
        )

        _ = try await coordinator.updateTrack(
            track,
            albumTracks: [track],
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        let activityRequests = await apiProbe.activityPeriodRequests
        #expect(activityRequests == ["daft punk"])
    }

    @Test("Year cache lookup uses album identity artist")
    func yearCacheLookupUsesAlbumIdentityArtist() async throws {
        let cache = MockCacheService()
        await cache.storeAlbumYear(
            artist: "Daft Punk",
            album: "Random Access Memories",
            year: 2013,
            confidence: 100
        )
        let coordinator = makeCoordinator(cache: cache)
        let track = makeTrack(
            id: "ram-1",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            year: 2012
        )

        let changes = try await coordinator.updateTrack(
            track,
            albumTracks: [track],
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        let yearChange = try #require(changes.first { $0.changeType == .yearUpdate })
        #expect(yearChange.newValue == "2013")
        #expect(yearChange.source == "Cache")
    }

    @Test("Year cache lookup does not use broad ampersand aliases without album artist")
    func yearCacheLookupDoesNotUseBroadAmpersandAliasesWithoutAlbumArtist() async throws {
        let cache = MockCacheService()
        await cache.storeAlbumYear(
            artist: "Daft Punk",
            album: "Random Access Memories",
            year: 2013,
            confidence: 100
        )
        let coordinator = makeCoordinator(cache: cache)
        let track = makeTrack(
            id: "ram-ampersand",
            artist: "Daft Punk & Pharrell Williams",
            album: "Random Access Memories",
            year: 2012
        )

        let changes = try await coordinator.updateTrack(
            track,
            albumTracks: [track],
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        #expect(!changes.contains { $0.changeType == .yearUpdate })
    }

    @Test("Year cache store uses album identity artist")
    func yearCacheStoreUsesAlbumIdentityArtist() async throws {
        let cache = MockCacheService()
        let apiService = UpdateAPIDouble(
            probe: APIRequestProbe(),
            yearResult: YearResult(
                year: 2013,
                isDefinitive: true,
                confidence: 100,
                yearScores: [2013: 100]
            )
        )
        let coordinator = makeCoordinator(apiService: apiService, cache: cache)
        let track = makeTrack(
            id: "ram-1",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            year: 2012
        )

        _ = try await coordinator.updateTrack(
            track,
            albumTracks: [track],
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        #expect(await cache.getAlbumYear(artist: "Daft Punk", album: "Random Access Memories")?.year == 2013)
        #expect(
            await cache.getAlbumYear(
                artist: "Daft Punk feat. Pharrell Williams",
                album: "Random Access Memories"
            ) == nil
        )
    }

    @Test("Prerelease pending mark uses album identity artist")
    func prereleasePendingMarkUsesAlbumIdentityArtist() async throws {
        let pending = PendingVerificationProbe(entry: nil, isVerificationNeeded: false)
        let coordinator = makeCoordinator(pendingVerification: pending)
        let prerelease = makeTrack(
            id: "ram-future",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            trackStatus: TrackKind.prerelease.rawValue
        )

        _ = try await coordinator.updateTrack(
            prerelease,
            albumTracks: [prerelease],
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        let marked = await pending.markedAlbums
        #expect(marked.first?.artist == "Daft Punk")
        #expect(marked.first?.album == "Random Access Memories")
        #expect(marked.first?.reason == "prerelease")
    }

    @Test("Fresh album pending mark uses album identity artist")
    func freshAlbumPendingMarkUsesAlbumIdentityArtist() async throws {
        let currentYear = Calendar.current.component(.year, from: Date())
        let pending = PendingVerificationProbe(entry: nil, isVerificationNeeded: false)
        let apiService = UpdateAPIDouble(
            probe: APIRequestProbe(),
            yearResult: YearResult(
                year: currentYear - 1,
                isDefinitive: false,
                confidence: 100,
                yearScores: [currentYear - 1: 100]
            )
        )
        let coordinator = makeCoordinator(
            apiService: apiService,
            pendingVerification: pending,
            disabledSources: [.discogs, .itunes]
        )
        let track = makeTrack(
            id: "ram-fresh",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            year: currentYear - 2,
            metadata: .init(releaseYear: currentYear)
        )

        _ = try await coordinator.updateTrack(
            track,
            albumTracks: [track],
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        let marked = await pending.markedAlbums
        #expect(marked.first?.artist == "Daft Punk")
        #expect(marked.first?.album == "Random Access Memories")
        #expect(marked.first?.reason == "stale_api_data_for_fresh_album")
    }

    @Test("Recent fallback rejection lookup uses album identity artist")
    func recentFallbackRejectionLookupUsesAlbumIdentityArtist() async throws {
        let apiProbe = APIRequestProbe()
        let apiService = UpdateAPIDouble(probe: apiProbe)
        let pendingEntry = PendingAlbumEntry(
            id: "daft-punk-random-access-memories",
            artist: "Daft Punk",
            album: "Random Access Memories",
            reason: "suspicious_year_change"
        )
        let pending = PendingVerificationProbe(entries: [pendingEntry], isVerificationNeeded: false)
        let coordinator = makeCoordinator(
            apiService: apiService,
            pendingVerification: pending
        )
        let track = makeTrack(
            id: "ram-rejected",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            year: 2012
        )

        let changes = try await coordinator.updateTrack(
            track,
            albumTracks: [track],
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        #expect(!changes.contains { $0.changeType == .yearUpdate })
        #expect(await apiProbe.requestCount == 0)
    }

    @Test("Recent fallback rejection lookup accepts legacy artist aliases")
    func recentFallbackRejectionLookupAcceptsLegacyArtistAliases() async throws {
        let apiProbe = APIRequestProbe()
        let apiService = UpdateAPIDouble(probe: apiProbe)
        let pendingEntry = PendingAlbumEntry(
            id: "daft-punk-feat-pharrell-williams-random-access-memories",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            reason: "suspicious_year_change"
        )
        let pending = PendingVerificationProbe(entries: [pendingEntry], isVerificationNeeded: false)
        let coordinator = makeCoordinator(
            apiService: apiService,
            pendingVerification: pending
        )
        let track = makeTrack(
            id: "ram-rejected-legacy",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            year: 2012,
            metadata: .init(albumArtist: "Daft Punk")
        )

        let changes = try await coordinator.updateTrack(
            track,
            albumTracks: [track],
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        #expect(!changes.contains { $0.changeType == .yearUpdate })
        #expect(await apiProbe.requestCount == 0)
    }

    @Test("Recent fallback rejection checks legacy aliases after non-fallback canonical entry")
    func recentFallbackRejectionChecksLegacyAliasesAfterNonFallbackCanonicalEntry() async throws {
        let apiProbe = APIRequestProbe()
        let apiService = UpdateAPIDouble(probe: apiProbe)
        let canonicalEntry = PendingAlbumEntry(
            id: "daft-punk-random-access-memories",
            artist: "Daft Punk",
            album: "Random Access Memories",
            reason: "prerelease"
        )
        let legacyEntry = PendingAlbumEntry(
            id: "daft-punk-feat-pharrell-williams-random-access-memories",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            reason: "suspicious_year_change"
        )
        let pending = PendingVerificationProbe(
            entries: [canonicalEntry, legacyEntry],
            isVerificationNeeded: false
        )
        let coordinator = makeCoordinator(
            apiService: apiService,
            pendingVerification: pending
        )
        let track = makeTrack(
            id: "ram-rejected-mixed",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            year: 2012,
            metadata: .init(albumArtist: "Daft Punk")
        )

        let changes = try await coordinator.updateTrack(
            track,
            albumTracks: [track],
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        #expect(!changes.contains { $0.changeType == .yearUpdate })
        #expect(await apiProbe.requestCount == 0)
    }

    @Test("Year write batching groups tracks by album identity")
    func yearWriteBatchingGroupsTracksByAlbumIdentity() async throws {
        let bridge = MockAppleScriptClient()
        let coordinator = makeCoordinator(
            script: bridge,
            runtimeConfiguration: UpdateRuntimeConfiguration(
                areBatchUpdatesEnabled: true,
                maxBatchUpdateSize: 5
            )
        )
        let firstTrack = makeTrack(
            id: "ram-1",
            artist: "Daft Punk",
            album: "Random Access Memories",
            year: 2012
        )
        let secondTrack = makeTrack(
            id: "ram-2",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            year: 2012
        )
        await bridge.setFetchedTracks([firstTrack, secondTrack])

        let result = try await coordinator.applyAcceptedChanges([
            acceptedYearChange(for: firstTrack, year: 2013),
            acceptedYearChange(for: secondTrack, year: 2013),
        ], progressHandler: ignoreAlbumIdentityProgress)

        let batches = await bridge.batchUpdates
        #expect(batches.count == 1)
        #expect(batches.first?.map(\.trackID) == ["ram-1", "ram-2"])
        #expect(result.entries.map(\.trackID) == ["ram-1", "ram-2"])
    }

    @Test("Default update context groups collaboration tracks by album identity")
    func defaultUpdateContextGroupsCollaborationTracksByAlbumIdentity() async throws {
        let bridge = MockAppleScriptClient()
        let coordinator = makeCoordinator(
            script: bridge,
            runtimeConfiguration: UpdateRuntimeConfiguration(
                areBatchUpdatesEnabled: true,
                maxBatchUpdateSize: 5
            )
        )
        let firstTrack = makeTrack(
            id: "ram-1",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories"
        )
        let secondTrack = makeTrack(
            id: "ram-2",
            artist: "Daft Punk feat. Julian Casablancas",
            album: "Random Access Memories",
            year: 2013
        )
        await bridge.setFetchedTracks([firstTrack, secondTrack])

        let result = try await coordinator.updateTracks(
            [firstTrack, secondTrack],
            options: UpdateOptions(updateGenre: false, updateYear: true),
            progressHandler: ignoreAlbumIdentityProgress
        )

        let writes = await bridge.writtenProperties
        #expect(writes.map(\.trackID) == ["ram-1"])
        #expect(writes.first?.value == "2013")
        #expect(result.entries.map(\.trackID) == ["ram-1"])
    }

    @Test("Default update context keeps shared guest aliases in separate album identities")
    func defaultUpdateContextKeepsSharedGuestAliasesInSeparateAlbumIdentities() async throws {
        let bridge = MockAppleScriptClient()
        let coordinator = makeCoordinator(script: bridge)
        let firstTrack = makeTrack(
            id: "first-guest",
            artist: "Guest Singer",
            album: "Greatest Hits",
            metadata: .init(albumArtist: "Original Artist")
        )
        let secondTrack = makeTrack(
            id: "second-guest",
            artist: "Guest Singer",
            album: "Greatest Hits",
            year: 1990,
            metadata: .init(albumArtist: "Compilation Artist")
        )
        await bridge.setFetchedTracks([firstTrack, secondTrack])

        let result = try await coordinator.updateTracks(
            [firstTrack, secondTrack],
            options: UpdateOptions(updateGenre: false, updateYear: true),
            progressHandler: ignoreAlbumIdentityProgress
        )

        let writes = await bridge.writtenProperties
        #expect(writes.isEmpty)
        #expect(result.entries.isEmpty)
    }

    @Test("Album context helper enriches MusicKit tracks before grouping")
    func albumContextHelperEnrichesMusicKitTracksBeforeGrouping() async {
        let bridge = MockAppleScriptClient()
        let mapper = TrackIDMapper()
        let coordinator = makeCoordinator(script: bridge, idMapper: mapper)
        let firstMusicKitTrack = makeTrack(
            id: "mk-1",
            name: "Get Lucky",
            artist: "Pharrell Williams",
            album: "Random Access Memories"
        )
        let secondMusicKitTrack = makeTrack(
            id: "mk-2",
            name: "Instant Crush",
            artist: "Julian Casablancas",
            album: "Random Access Memories"
        )
        let firstAppleScriptTrack = makeTrack(
            id: "as-1",
            name: "Get Lucky",
            artist: "Pharrell Williams",
            album: "Random Access Memories",
            metadata: .init(albumArtist: "Daft Punk")
        )
        let secondAppleScriptTrack = makeTrack(
            id: "as-2",
            name: "Instant Crush",
            artist: "Julian Casablancas",
            album: "Random Access Memories",
            metadata: .init(albumArtist: "Daft Punk")
        )
        await mapper.refreshMapping(
            musicKitTracks: [firstMusicKitTrack, secondMusicKitTrack],
            appleScriptTracks: [firstAppleScriptTrack, secondAppleScriptTrack]
        )

        let context = await coordinator.albumContextTracksByTrackID(
            for: [firstMusicKitTrack, secondMusicKitTrack]
        )

        #expect(Set(context["mk-1"]?.map(\.id) ?? []) == ["mk-1", "mk-2"])
        #expect(Set(context["mk-2"]?.map(\.id) ?? []) == ["mk-1", "mk-2"])
    }

    @Test("Default update context groups tracks after AppleScript album artist enrichment")
    func defaultUpdateContextGroupsTracksAfterAppleScriptAlbumArtistEnrichment() async throws {
        let bridge = MockAppleScriptClient()
        let mapper = TrackIDMapper()
        let coordinator = makeCoordinator(script: bridge, idMapper: mapper)
        let firstMusicKitTrack = makeTrack(
            id: "mk-1",
            name: "Get Lucky",
            artist: "Pharrell Williams",
            album: "Random Access Memories"
        )
        let secondMusicKitTrack = makeTrack(
            id: "mk-2",
            name: "Instant Crush",
            artist: "Julian Casablancas",
            album: "Random Access Memories",
            year: 2001
        )
        let firstAppleScriptTrack = makeTrack(
            id: "as-1",
            name: "Get Lucky",
            artist: "Pharrell Williams",
            album: "Random Access Memories",
            metadata: .init(albumArtist: "Daft Punk")
        )
        let secondAppleScriptTrack = makeTrack(
            id: "as-2",
            name: "Instant Crush",
            artist: "Julian Casablancas",
            album: "Random Access Memories",
            year: 2001,
            metadata: .init(albumArtist: "Daft Punk")
        )
        await mapper.refreshMapping(
            musicKitTracks: [firstMusicKitTrack, secondMusicKitTrack],
            appleScriptTracks: [firstAppleScriptTrack, secondAppleScriptTrack]
        )

        let result = try await coordinator.updateTracks(
            [firstMusicKitTrack, secondMusicKitTrack],
            options: UpdateOptions(updateGenre: false, updateYear: true),
            progressHandler: ignoreAlbumIdentityProgress
        )

        let writes = await bridge.writtenProperties
        #expect(writes.map(\.trackID) == ["as-1"])
        #expect(writes.first?.value == "2001")
        #expect(result.entries.map(\.trackID) == ["mk-1"])
    }

    @Test("Write invalidation clears canonical and legacy album keys")
    func writeInvalidationClearsCanonicalAndLegacyAlbumKeys() async throws {
        let cache = MockCacheService()
        await seedAlbumIdentityInvalidationCache(cache)
        let bridge = MockAppleScriptClient()
        let coordinator = makeCoordinator(script: bridge, cache: cache)
        let track = makeTrack(
            id: "ram-1",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            year: 2012,
            metadata: .init(originalArtist: "The Robots")
        )

        _ = try await coordinator.applyAcceptedChanges([
            acceptedYearChange(for: track, year: 2013),
        ], progressHandler: ignoreAlbumIdentityProgress)

        #expect(await cache.getAlbumYear(artist: "Daft Punk", album: "Random Access Memories") == nil)
        #expect(
            await cache.getAlbumYear(
                artist: "Daft Punk feat. Pharrell Williams",
                album: "Random Access Memories"
            ) == nil
        )
        #expect(await cache.getAlbumYear(artist: "The Robots", album: "Random Access Memories") == nil)
        #expect(await cache.getCachedAPIResult(
            artist: "Daft Punk",
            album: "Random Access Memories",
            source: "MusicBrainz"
        ) == nil)
        #expect(await cache.getCachedAPIResult(
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            source: "MusicBrainz"
        ) == nil)
    }

    @Test("Album cleaning invalidates identity aliases with cleaned album")
    func albumCleaningInvalidatesIdentityAliasesWithCleanedAlbum() async throws {
        let cache = MockCacheService()
        await seedOriginalArtistCleanedAlbumCache(cache)
        let bridge = MockAppleScriptClient()
        let coordinator = makeCoordinator(script: bridge, cache: cache)
        let track = makeTrack(
            id: "ram-clean",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories (Deluxe Edition)",
            metadata: .init(originalArtist: "The Robots")
        )

        _ = try await coordinator.applyAcceptedChanges([
            acceptedAlbumCleaningChange(for: track, album: "Random Access Memories"),
        ], progressHandler: ignoreAlbumIdentityProgress)

        #expect(await cache.getAlbumYear(artist: "The Robots", album: "Random Access Memories") == nil)
        #expect(await cache.getAlbumYear(artist: "Daft Punk", album: "Random Access Memories") == nil)
        #expect(
            await cache.getAlbumYear(
                artist: "Daft Punk feat. Pharrell Williams",
                album: "Random Access Memories"
            ) == nil
        )
        #expect(await cache.getAlbumYear(artist: "The Robots", album: "Random Access Memories (Deluxe Edition)") == nil)
        #expect(await cache.getAlbumYear(artist: "Daft Punk", album: "Random Access Memories (Deluxe Edition)") == nil)
        #expect(
            await cache.getAlbumYear(
                artist: "Daft Punk feat. Pharrell Williams",
                album: "Random Access Memories (Deluxe Edition)"
            ) == nil
        )
        #expect(await cache.getCachedAPIResult(
            artist: "The Robots",
            album: "Random Access Memories",
            source: "MusicBrainz"
        ) == nil)
        #expect(await cache.getCachedAPIResult(
            artist: "Daft Punk",
            album: "Random Access Memories",
            source: "MusicBrainz"
        ) == nil)
        #expect(await cache.getCachedAPIResult(
            artist: "The Robots",
            album: "Random Access Memories (Deluxe Edition)",
            source: "MusicBrainz"
        ) == nil)
        #expect(await cache.getCachedAPIResult(
            artist: "Daft Punk",
            album: "Random Access Memories (Deluxe Edition)",
            source: "MusicBrainz"
        ) == nil)
        #expect(await cache.getCachedAPIResult(
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories (Deluxe Edition)",
            source: "MusicBrainz"
        ) == nil)
        #expect(await cache.getCachedAPIResult(
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            source: "MusicBrainz"
        ) == nil)
    }

    private func makeCoordinator(
        apiService: any ExternalAPIService = MockAPIService(),
        script: MockAppleScriptClient = MockAppleScriptClient(),
        cache: MockCacheService = MockCacheService(),
        idMapper: (any TrackIDMapping)? = nil,
        pendingVerification: (any PendingVerificationService)? = nil,
        runtimeConfiguration: UpdateRuntimeConfiguration = UpdateRuntimeConfiguration(),
        disabledSources: Set<APISource> = []
    ) -> UpdateCoordinator {
        let api = makeAPIOrchestrator(
            musicBrainz: apiService,
            discogs: apiService,
            appleMusic: apiService,
            cache: cache,
            disabledSources: disabledSources
        )
        let undoDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AlbumIdentityFlowTests-\(UUID().uuidString)")
        return UpdateCoordinator(
            dependencies: UpdateCoordinatorDependencies(
                apiOrchestrator: api,
                scriptBridge: script,
                trackStore: MockTrackStore(),
                cache: cache,
                undoCoordinator: UndoCoordinator(scriptBridge: script, directory: undoDirectory),
                idMapper: idMapper,
                pendingVerificationService: pendingVerification
            ),
            genreDeterminator: GenreDeterminator(),
            yearDeterminator: YearDeterminator(),
            runtimeConfiguration: runtimeConfiguration
        )
    }

    private struct TrackFixtureMetadata {
        var originalArtist: String?
        var releaseYear: Int?
        var albumArtist: String?
    }

    private func makeTrack(
        id: String,
        name: String? = nil,
        artist: String,
        album: String,
        year: Int? = nil,
        trackStatus: String? = nil,
        metadata: TrackFixtureMetadata = TrackFixtureMetadata()
    ) -> Track {
        Track(
            id: id,
            name: name ?? "Track \(id)",
            artist: artist,
            album: album,
            year: year,
            trackStatus: trackStatus,
            originalArtist: metadata.originalArtist,
            releaseYear: metadata.releaseYear,
            albumArtist: metadata.albumArtist
        )
    }

    private func acceptedYearChange(for track: Track, year: Int) -> ProposedChange {
        ProposedChange(
            track: track,
            changeType: .yearUpdate,
            oldValue: track.year.map(String.init),
            newValue: String(year),
            confidence: 100,
            source: "Album Identity Test",
            isAccepted: true
        )
    }

    private func acceptedAlbumCleaningChange(for track: Track, album: String) -> ProposedChange {
        ProposedChange(
            track: track,
            changeType: .albumCleaning,
            oldValue: track.album,
            newValue: album,
            confidence: 100,
            source: "Album Identity Test",
            isAccepted: true
        )
    }

    private func seedAlbumIdentityInvalidationCache(_ cache: MockCacheService) async {
        await cache.storeAlbumYear(
            artist: "Daft Punk",
            album: "Random Access Memories",
            year: 2013,
            confidence: 100
        )
        await cache.storeAlbumYear(
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            year: 2012,
            confidence: 100
        )
        await cache.storeAlbumYear(
            artist: "The Robots",
            album: "Random Access Memories",
            year: 2011,
            confidence: 100
        )
        await cache.setCachedAPIResult(CachedAPIResult(
            artist: "Daft Punk",
            album: "Random Access Memories",
            year: 2013,
            source: "MusicBrainz",
            timestamp: Date(),
            ttl: 3600
        ))
        await cache.setCachedAPIResult(CachedAPIResult(
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            year: 2012,
            source: "MusicBrainz",
            timestamp: Date(),
            ttl: 3600
        ))
    }

    private func seedOriginalArtistCleanedAlbumCache(_ cache: MockCacheService) async {
        let artists = ["Daft Punk", "Daft Punk feat. Pharrell Williams", "The Robots"]
        let albums = ["Random Access Memories", "Random Access Memories (Deluxe Edition)"]

        for artist in artists {
            for album in albums {
                await cache.storeAlbumYear(
                    artist: artist,
                    album: album,
                    year: 2013,
                    confidence: 100
                )
                await cache.setCachedAPIResult(CachedAPIResult(
                    artist: artist,
                    album: album,
                    year: 2013,
                    source: "MusicBrainz",
                    timestamp: Date(),
                    ttl: 3600
                ))
            }
        }
    }
}

private func ignoreAlbumIdentityProgress(_ update: ProgressUpdate) {
    _ = update
}
