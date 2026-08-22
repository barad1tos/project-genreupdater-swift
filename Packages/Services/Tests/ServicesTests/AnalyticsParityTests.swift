import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("Python analytics parity")
struct AnalyticsParityTests {
    @Test("Every Python timing domain maps to a typed Swift operation")
    func operationMapping() {
        let mapping: [(python: String, swift: AnalyticsOperation)] = [
            ("applescript_run_script", .appleScriptRun),
            ("applescript_fetch_by_ids", .appleScriptFetchIDs),
            ("applescript_fetch_all_ids", .appleScriptFetchIDs),
            ("discogs_release_details", .discogsReleaseDetails),
            ("discogs_master_release", .discogsPrimaryRelease),
            ("discogs_year_search", .discogsYearSearch),
            ("discogs_release_search", .discogsReleaseSearch),
            ("musicbrainz_artist_search", .musicBrainzArtistSearch),
            ("musicbrainz_artist_period", .musicBrainzArtistSearch),
            ("musicbrainz_artist_region", .musicBrainzArtistSearch),
            ("musicbrainz_release_search", .musicBrainzReleaseSearch),
            ("track_fetch_by_ids", .appleScriptFetchIDs),
            ("track_fetch_all", .libraryLoad),
            ("track_fetch_batches", .musicAppFetch),
            ("track_update", .batchWrite),
            ("track_artist_update", .batchWrite),
            ("year_discogs_update", .yearDetermination),
        ]

        #expect(mapping.count == 17)
        #expect(Set(mapping.map(\.python)).count == mapping.count)
        #expect(Set(mapping.map(\.swift)) == [
            .appleScriptRun,
            .appleScriptFetchIDs,
            .discogsReleaseDetails,
            .discogsPrimaryRelease,
            .discogsYearSearch,
            .discogsReleaseSearch,
            .musicBrainzArtistSearch,
            .musicBrainzReleaseSearch,
            .libraryLoad,
            .musicAppFetch,
            .batchWrite,
            .yearDetermination,
        ])
    }

    @Test("Mixed Python-derived events preserve the aggregate tuple")
    func aggregateTuple() {
        var configuration = AnalyticsConfig()
        configuration.enabled = true
        configuration.durationThresholds.shortMax = 2
        configuration.durationThresholds.mediumMax = 5
        configuration.durationThresholds.longMax = 10
        let sessionID = UUID()
        let events = [
            event(1, sessionID: sessionID, operation: .musicBrainzReleaseSearch, duration: 0.5, outcome: .succeeded),
            event(2, sessionID: sessionID, operation: .musicBrainzReleaseSearch, duration: 1.5, outcome: .failed),
            event(3, sessionID: sessionID, operation: .appleScriptBatchWrite, duration: 2, outcome: .succeeded),
            event(4, sessionID: sessionID, operation: .discogsReleaseSearch, duration: 6, outcome: .succeeded),
            event(5, sessionID: sessionID, operation: .batchProcess, duration: 8, outcome: .succeeded),
            event(6, sessionID: sessionID, operation: .batchWrite, duration: 12, outcome: .failed),
            event(7, sessionID: sessionID, operation: .batchWrite, duration: 30, outcome: .cancelled),
        ]

        let projection = AnalyticsBuilder.build(
            events: events,
            window: .currentSession,
            configuration: configuration
        )

        #expect(projection.summary.calls == 7)
        #expect(projection.summary.succeeded == 4)
        #expect(projection.summary.failed == 2)
        #expect(projection.summary.cancelled == 1)
        #expect(projection.summary.failed + projection.summary.cancelled == 3)
        #expect(projection.summary.successRate == 4.0 / 7.0)
        #expect(projection.summary.totalDurationSeconds == 60)
        #expect(projection.summary.averageDurationSeconds == 60.0 / 7.0)
        #expect(projection.summary.p95DurationSeconds == 30)
        #expect(projection.durationDistribution == .init(short: 3, medium: 0, long: 2, veryLong: 2))
        #expect(projection.operations.map(\.operationValue) == [
            "batch.write",
            "batch.process",
            "discogs.release_search",
            "applescript.batch_write",
            "musicbrainz.release_search",
        ])

        let disabled = AnalyticsBuilder.build(
            events: events,
            window: .currentSession,
            configuration: AnalyticsConfig()
        )
        #expect(disabled.state == .disabled)
        #expect(disabled.summary == .empty)
        #expect(disabled.operations.isEmpty)
    }

    @Test("API result cache reads use the existing analytics recorder")
    func apiCacheRead() async {
        let cache = MockCacheService()
        await cache.setCachedAPIResult(CachedAPIResult(
            artist: "Artist",
            album: "Album",
            year: 2001,
            source: "musicbrainz",
            timestamp: .now,
            ttl: 3600,
            metadata: [
                "confidence": "90",
                "rawScore": "90",
                "isDefinitive": "true",
            ]
        ))
        let analytics = ParityAnalyticsProbe()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(yearResult: YearResult(year: 1999)),
            discogs: MockAPIService(),
            appleMusic: MockAPIService(),
            cache: cache,
            disabledSources: [.discogs, .itunes]
        ) {
            $0.analytics = analytics
        }

        let result = await orchestrator.getAlbumYear(
            artist: "Artist",
            album: "Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(result.year == 2001)
        #expect(await analytics.operations == [.apiResultCacheRead])
    }

    private func event(
        _ index: Int,
        sessionID: UUID,
        operation: AnalyticsOperation,
        duration: Double,
        outcome: AnalyticsOutcome
    ) -> StoredAnalyticsEvent {
        StoredAnalyticsEvent(
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(index))),
            sessionID: sessionID,
            operationValue: operation.rawValue,
            startedAt: Date(timeIntervalSince1970: Double(index)),
            durationSeconds: duration,
            outcome: outcome
        )
    }
}

private actor ParityAnalyticsProbe: AnalyticsService {
    private(set) var operations: [AnalyticsOperation] = []

    func record(_ operation: AnalyticsOperation, duration _: Duration, outcome _: AnalyticsOutcome) {
        operations.append(operation)
    }
}
