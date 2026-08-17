import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("UpdateCoordinator — local-first year repair")
struct YearLocalFirstTests {
    /// Builds a coordinator whose default API fixtures yield no usable year;
    /// callers can inject API results, cache state, and year policy.
    private func makeCoordinator(
        apiProbe: APIRequestProbe? = nil,
        apiYearResult: YearResult = YearResult(year: nil, confidence: 0, yearScores: [:]),
        apiReleaseCandidates: [ReleaseCandidate] = [],
        cache: MockCacheService? = nil,
        yearDeterminator: YearDeterminator = YearDeterminator(),
        runtimeConfiguration: UpdateRuntimeConfiguration = UpdateRuntimeConfiguration()
    ) async -> UpdateCoordinator {
        let bridge = MockAppleScriptClient()
        let effectiveCache = cache ?? MockCacheService()
        let undoDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YearLocalFirstTests-\(UUID().uuidString)")
        let orchestrator: APIOrchestrator
        if let apiProbe {
            orchestrator = makeAPIOrchestrator(
                musicBrainz: UpdateAPIDouble(
                    probe: apiProbe,
                    yearResult: apiYearResult,
                    releaseCandidates: apiReleaseCandidates
                ),
                discogs: UpdateAPIDouble(probe: apiProbe),
                appleMusic: UpdateAPIDouble(probe: apiProbe)
            )
        } else {
            let apiService = MockAPIService(yearResult: apiYearResult)
            orchestrator = makeAPIOrchestrator(
                musicBrainz: apiService,
                discogs: apiService,
                appleMusic: apiService
            )
        }

        return UpdateCoordinator(
            dependencies: UpdateDependencies(
                apiOrchestrator: orchestrator,
                scriptBridge: bridge,
                stores: .init(
                    trackStore: MockTrackStore(),
                    cache: effectiveCache
                ),
                undoCoordinator: UndoCoordinator(
                    scriptBridge: bridge,
                    directory: undoDirectory
                ),
                idMapper: nil,
                librarySnapshotService: nil
            ),
            genreDeterminator: GenreDeterminator(),
            yearDeterminator: yearDeterminator,
            runtimeConfiguration: runtimeConfiguration
        )
    }

    private func albumTrack(id: String, name: String, year: Int?, releaseYear: Int?) -> Track {
        Track(
            id: id,
            name: name,
            artist: "паліндром",
            album: "Декілька пісень невизначеності (ч.1)",
            genre: "Alternative",
            year: year,
            trackStatus: nil, // nil trackStatus = available/editable
            releaseYear: releaseYear,
            albumArtist: "паліндром"
        )
    }

    @Test("Repairs a valid outlier year from the album dominant without an API result")
    func repairsDominantOutlier() async throws {
        let runtimeConfiguration = UpdateRuntimeConfiguration(
            policies: .init(missingYearThreshold: 95)
        )
        let coordinator = await makeCoordinator(runtimeConfiguration: runtimeConfiguration)

        let outlier = albumTrack(id: "MK-zabuty", name: "Забути", year: 2024, releaseYear: 2026)
        let consistent = (1 ... 6).map {
            albumTrack(id: "MK-\($0)", name: "Track \($0)", year: 2026, releaseYear: 2026)
        }
        let albumTracks = [outlier] + consistent

        let change = try await coordinator.determineYearChange(
            track: outlier,
            albumTracks: albumTracks,
            forceYearLookup: false
        )

        let yearChange = try #require(change)
        #expect(yearChange.changeType == .yearUpdate)
        #expect(yearChange.oldValue == "2024")
        #expect(yearChange.newValue == "2026")
    }

    @Test("Missing-year threshold does not suppress a single-provider API correction")
    func allowsAPICorrection() async throws {
        let apiProbe = APIRequestProbe()
        let apiResult = YearResult(
            year: 2020,
            isDefinitive: true,
            confidence: 90,
            yearScores: [2020: 90]
        )
        let runtimeConfiguration = UpdateRuntimeConfiguration(
            policies: .init(missingYearThreshold: 95)
        )
        let coordinator = await makeCoordinator(
            apiProbe: apiProbe,
            apiYearResult: apiResult,
            runtimeConfiguration: runtimeConfiguration
        )
        let track = albumTrack(id: "MK-existing", name: "Existing", year: 1969, releaseYear: nil)

        let change = try await coordinator.determineYearChange(
            track: track,
            albumTracks: [track],
            forceYearLookup: false
        )

        let yearChange = try #require(change)
        #expect(yearChange.newValue == "2020")
        #expect(yearChange.source == "API")
    }

    @Test("Missing-year threshold still rejects a weak fill")
    func rejectsWeakFill() async throws {
        let apiProbe = APIRequestProbe()
        let apiResult = YearResult(
            year: 2020,
            isDefinitive: true,
            confidence: 90,
            yearScores: [2020: 90]
        )
        let runtimeConfiguration = UpdateRuntimeConfiguration(
            policies: .init(missingYearThreshold: 95)
        )
        let coordinator = await makeCoordinator(
            apiProbe: apiProbe,
            apiYearResult: apiResult,
            runtimeConfiguration: runtimeConfiguration
        )
        let track = albumTrack(id: "MK-missing", name: "Missing", year: nil, releaseYear: nil)

        let change = try await coordinator.determineYearChange(
            track: track,
            albumTracks: [track],
            forceYearLookup: false
        )

        #expect(change == nil)
    }

    @Test("Zero year is treated as missing for the confidence threshold")
    func rejectsWeakFillForZeroYear() async throws {
        let runtimeConfiguration = UpdateRuntimeConfiguration(
            policies: .init(missingYearThreshold: 95)
        )
        let coordinator = await makeCoordinator(runtimeConfiguration: runtimeConfiguration)
        let track = albumTrack(id: "MK-zero", name: "Zero", year: 0, releaseYear: 1970)
        let peer = albumTrack(id: "MK-peer", name: "Peer", year: nil, releaseYear: 1970)

        let change = try await coordinator.determineYearChange(
            track: track,
            albumTracks: [track, peer],
            forceYearLookup: false
        )

        #expect(change == nil)
    }

    @Test("Does not repair when the album year signal is ambiguous")
    func skipsRepairWhenAlbumYearAmbiguous() async throws {
        let coordinator = await makeCoordinator()

        // No dominant (3-way split) and no release-year consensus (varied
        // releaseYears → ambiguous signal) → must defer to the API, not guess.
        let outlier = albumTrack(id: "MK-a", name: "A", year: 2024, releaseYear: 2018)
        let mixed = [
            albumTrack(id: "MK-b", name: "B", year: 2019, releaseYear: 2019),
            albumTrack(id: "MK-c", name: "C", year: 2020, releaseYear: 2020),
        ]
        let albumTracks = [outlier] + mixed

        let change = try await coordinator.determineYearChange(
            track: outlier,
            albumTracks: albumTracks,
            forceYearLookup: false
        )

        #expect(change == nil)
    }

    @Test("Dominant album year wins over a disagreeing release-year signal")
    func dominantWinsOverDisagreeingReleaseYear() async throws {
        let coordinator = await makeCoordinator()

        // The dominant track year (2020) differs from the unanimous release-year
        // signal (2018). Python `_try_local_sources` returns the dominant first,
        // so the repair targets 2020 — not the read-only release year.
        let outlier = albumTrack(id: "MK-out", name: "Out", year: 2024, releaseYear: 2018)
        let consistent = (1 ... 6).map {
            albumTrack(id: "MK-\($0)", name: "Track \($0)", year: 2020, releaseYear: 2018)
        }
        let albumTracks = [outlier] + consistent

        let change = try await coordinator.determineYearChange(
            track: outlier,
            albumTracks: albumTracks,
            forceYearLookup: false
        )

        let yearChange = try #require(change)
        #expect(yearChange.oldValue == "2024")
        #expect(yearChange.newValue == "2020")
    }

    @Test("Dominant metadata wins over a disagreeing high-confidence cache")
    func dominantWinsOverTrustedCache() async throws {
        let cache = MockCacheService()
        await cache.storeAlbumYear(
            artist: "паліндром",
            album: "Декілька пісень невизначеності (ч.1)",
            year: 2019,
            confidence: 100
        )
        let apiProbe = APIRequestProbe()
        let coordinator = await makeCoordinator(apiProbe: apiProbe, cache: cache)
        let outlier = albumTrack(id: "MK-out", name: "Out", year: 2024, releaseYear: nil)
        let consistent = (1 ... 6).map {
            albumTrack(id: "MK-\($0)", name: "Track \($0)", year: 2020, releaseYear: nil)
        }

        let change = try await coordinator.determineYearChange(
            track: outlier,
            albumTracks: [outlier] + consistent,
            forceYearLookup: false
        )

        let yearChange = try #require(change)
        #expect(yearChange.newValue == "2020")
        #expect(yearChange.source == "Dominant")
        #expect(await apiProbe.requestCount == 0)
    }

    @Test("Matching album dominant prevents a disagreeing trusted cache rewrite")
    func matchingAlbumDominantSkipsTrustedCacheRewrite() async throws {
        let cache = MockCacheService()
        await cache.storeAlbumYear(
            artist: "паліндром",
            album: "Декілька пісень невизначеності (ч.1)",
            year: 2019,
            confidence: 100
        )
        let apiProbe = APIRequestProbe()
        let coordinator = await makeCoordinator(apiProbe: apiProbe, cache: cache)
        let target = albumTrack(id: "MK-target", name: "Target", year: 2020, releaseYear: nil)
        let peers = (1 ... 6).map {
            albumTrack(id: "MK-\($0)", name: "Track \($0)", year: 2020, releaseYear: nil)
        }

        let change = try await coordinator.determineYearChange(
            track: target,
            albumTracks: [target] + peers,
            forceYearLookup: false
        )

        #expect(change == nil)
        #expect(await apiProbe.requestCount == 0)
    }

    @Test("Trusted cache wins over release-year consensus for an invalid editable year")
    func trustedCacheWinsOverConsensus() async throws {
        let cache = MockCacheService()
        await cache.storeAlbumYear(
            artist: "паліндром",
            album: "Декілька пісень невизначеності (ч.1)",
            year: 2019,
            confidence: 90
        )
        let coordinator = await makeCoordinator(cache: cache)
        let target = albumTrack(id: "MK-target", name: "Target", year: 0, releaseYear: 2018)
        let peer = albumTrack(id: "MK-peer", name: "Peer", year: nil, releaseYear: 2018)

        let change = try await coordinator.determineYearChange(
            track: target,
            albumTracks: [target, peer],
            forceYearLookup: false
        )

        let yearChange = try #require(change)
        #expect(yearChange.newValue == "2019")
        #expect(yearChange.source == "Cache")
    }

    @Test("Cache below the configured trust threshold falls through to consensus")
    func weakCacheFallsThroughToConsensus() async throws {
        let cache = MockCacheService()
        await cache.storeAlbumYear(
            artist: "паліндром",
            album: "Декілька пісень невизначеності (ч.1)",
            year: 2019,
            confidence: 94
        )
        let runtimeConfiguration = UpdateRuntimeConfiguration(
            policies: .init(cacheTrustThreshold: 95)
        )
        let coordinator = await makeCoordinator(
            cache: cache,
            runtimeConfiguration: runtimeConfiguration
        )
        let target = albumTrack(id: "MK-target", name: "Target", year: nil, releaseYear: 2018)
        let peer = albumTrack(id: "MK-peer", name: "Peer", year: nil, releaseYear: 2018)

        let change = try await coordinator.determineYearChange(
            track: target,
            albumTracks: [target, peer],
            forceYearLookup: false
        )

        let yearChange = try #require(change)
        #expect(yearChange.newValue == "2018")
        #expect(yearChange.source == "Consensus")
    }

    @Test("Weak cache without consensus reaches a fresh API result")
    func weakCacheWithoutConsensusUsesAPI() async throws {
        let cache = MockCacheService()
        await cache.storeAlbumYear(
            artist: "паліндром",
            album: "Декілька пісень невизначеності (ч.1)",
            year: 2019,
            confidence: 89
        )
        let apiProbe = APIRequestProbe()
        let coordinator = await makeCoordinator(
            apiProbe: apiProbe,
            apiReleaseCandidates: [
                ReleaseCandidate(
                    artist: "паліндром",
                    album: "Декілька пісень невизначеності (ч.1)",
                    year: 2021,
                    source: .musicBrainz,
                    mbReleaseGroupFirstYear: 2021
                ),
            ],
            cache: cache
        )
        let target = albumTrack(id: "MK-target", name: "Target", year: nil, releaseYear: nil)
        let peer = albumTrack(id: "MK-peer", name: "Peer", year: nil, releaseYear: nil)

        let change = try await coordinator.determineYearChange(
            track: target,
            albumTracks: [target, peer],
            forceYearLookup: false
        )

        let yearChange = try #require(change)
        #expect(yearChange.newValue == "2021")
        #expect(await apiProbe.requestCount > 0)
    }

    @Test("Trusted cache disambiguates conflicting live release years")
    func trustedCacheDisambiguatesReleaseYears() async throws {
        let cache = MockCacheService()
        await cache.storeAlbumYear(
            artist: "паліндром",
            album: "Декілька пісень невизначеності (ч.1)",
            year: 2017,
            confidence: 95
        )
        let apiProbe = APIRequestProbe()
        let coordinator = await makeCoordinator(apiProbe: apiProbe, cache: cache)
        let target = albumTrack(id: "MK-a", name: "A", year: 2024, releaseYear: 2018)
        let mixed = [
            albumTrack(id: "MK-b", name: "B", year: 2019, releaseYear: 2019),
            albumTrack(id: "MK-c", name: "C", year: 2020, releaseYear: 2020),
        ]

        let change = try await coordinator.determineYearChange(
            track: target,
            albumTracks: [target] + mixed,
            forceYearLookup: false
        )

        let yearChange = try #require(change)
        #expect(yearChange.newValue == "2017")
        #expect(yearChange.source == "Cache")
        #expect(await apiProbe.requestCount == 0)
    }

    @Test("Uses the one release year present without consulting APIs")
    func partialConsensusSkipsAPI() async throws {
        let apiProbe = APIRequestProbe()
        let coordinator = await makeCoordinator(apiProbe: apiProbe)
        let target = albumTrack(id: "MK-target", name: "Target", year: nil, releaseYear: 2010)
        let peer = albumTrack(id: "MK-peer", name: "Peer", year: nil, releaseYear: nil)

        let change = try await coordinator.determineYearChange(
            track: target,
            albumTracks: [target, peer],
            forceYearLookup: false
        )

        let yearChange = try #require(change)
        #expect(yearChange.changeType == .yearUpdate)
        #expect(yearChange.newValue == "2010")
        #expect(yearChange.confidence == 80)
        #expect(yearChange.source == "Consensus")
        #expect(await apiProbe.requestCount == 0)
    }

    @Test("Consensus persists with its configured confidence")
    func consensusPersistsConfiguredConfidence() async throws {
        var logic = YearLogicConfig()
        logic.consensusYearConfidence = 73
        let cache = MockCacheService()
        let coordinator = await makeCoordinator(
            cache: cache,
            yearDeterminator: YearDeterminator(validator: YearValidator(config: logic))
        )
        let target = albumTrack(id: "MK-target", name: "Target", year: nil, releaseYear: 2010)
        let peer = albumTrack(id: "MK-peer", name: "Peer", year: nil, releaseYear: nil)

        let change = try await coordinator.determineYearChange(
            track: target,
            albumTracks: [target, peer],
            forceYearLookup: false
        )
        let cached = await cache.getAlbumYear(
            artist: target.albumIdentity.artist,
            album: target.albumIdentity.album
        )

        let yearChange = try #require(change)
        #expect(yearChange.newValue == "2010")
        #expect(yearChange.confidence == 73)
        #expect(cached?.year == 2010)
        #expect(cached?.confidence == 73)
    }
}
