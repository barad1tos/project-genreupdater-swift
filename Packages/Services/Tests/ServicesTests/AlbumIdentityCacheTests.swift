import Testing
@testable import Core
@testable import Services

extension AlbumIdentityFlowTests {
    @Test("Trusted legacy cache alias wins when the canonical entry is weak")
    func trustedLegacyCacheAliasWinsOverWeakCanonicalEntry() async throws {
        let cache = MockCacheService()
        await cache.storeAlbumYear(
            artist: "Daft Punk",
            album: "Random Access Memories",
            year: 2010,
            confidence: 89
        )
        await cache.storeAlbumYear(
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            year: 2013,
            confidence: 95
        )
        let apiProbe = APIRequestProbe()
        let coordinator = makeCoordinator(
            apiService: UpdateAPIDouble(probe: apiProbe),
            cache: cache
        )
        let track = makeTrack(
            id: "ram-cache-alias",
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

        let yearChange = try #require(changes.first { $0.changeType == .yearUpdate })
        #expect(yearChange.newValue == "2013")
        #expect(yearChange.source == "Cache")
        #expect(await apiProbe.albumRequests.isEmpty)
    }

    @Test("Trusted canonical cache entry keeps precedence over a stronger legacy alias")
    func trustedCanonicalCacheEntryWinsOverLegacyAlias() async throws {
        let cache = MockCacheService()
        await cache.storeAlbumYear(
            artist: "Daft Punk",
            album: "Random Access Memories",
            year: 2013,
            confidence: 90
        )
        await cache.storeAlbumYear(
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            year: 2010,
            confidence: 100
        )
        let apiProbe = APIRequestProbe()
        let coordinator = makeCoordinator(
            apiService: UpdateAPIDouble(probe: apiProbe),
            cache: cache
        )
        let track = makeTrack(
            id: "ram-canonical-cache",
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

        let yearChange = try #require(changes.first { $0.changeType == .yearUpdate })
        #expect(yearChange.newValue == "2013")
        #expect(yearChange.source == "Cache")
        #expect(await apiProbe.albumRequests.isEmpty)
    }

    @Test("Weaker consensus does not replace trusted cache evidence")
    func weakerConsensusKeepsTrustedCache() async throws {
        let cache = MockCacheService()
        await cache.storeAlbumYear(
            artist: "Daft Punk",
            album: "Random Access Memories",
            year: 2019,
            confidence: 90
        )
        let runtimeConfiguration = UpdateRuntimeConfiguration(
            policies: .init(
                minimumYearUpdateConfidence: 95,
                cacheTrustThreshold: 90
            )
        )
        let coordinator = makeCoordinator(
            cache: cache,
            runtimeConfiguration: runtimeConfiguration
        )
        let target = makeTrack(
            id: "ram-consensus-target",
            artist: "Daft Punk",
            album: "Random Access Memories",
            metadata: .init(releaseYear: 2018)
        )
        let peer = makeTrack(
            id: "ram-consensus-peer",
            artist: "Daft Punk",
            album: "Random Access Memories",
            metadata: .init(releaseYear: 2018)
        )

        let changes = try await coordinator.updateTrack(
            target,
            albumTracks: [target, peer],
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )
        let cachedEntry = await cache.getAlbumYear(
            artist: "Daft Punk",
            album: "Random Access Memories"
        )

        #expect(!changes.contains { $0.changeType == .yearUpdate })
        #expect(cachedEntry?.year == 2019)
        #expect(cachedEntry?.confidence == 90)
    }
}
