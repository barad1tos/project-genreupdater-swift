// APIOrchestrator.swift — Parallel multi-source API coordinator
// Phase 4: API + Cache

import Core
import Foundation
import OSLog

// MARK: - APIOrchestrator

/// Coordinates parallel API calls across MusicBrainz, Discogs, and Apple Music.
///
/// Each source is queried concurrently with an independent timeout. Results are
/// aggregated by year score -- the year with the highest combined confidence
/// across all sources wins. Sources that fail or time out are silently excluded.
///
/// ```swift
/// let orchestrator = APIOrchestrator(
///     musicBrainz: MusicBrainzClient(),
///     discogs: DiscogsClient(token: "..."),
///     appleMusic: AppleMusicSearchClient(),
///     timeout: .seconds(15)
/// )
/// let result = await orchestrator.getAlbumYear(
///     artist: "Iron Maiden", album: "Powerslave",
///     currentLibraryYear: nil, earliestTrackAddedYear: nil
/// )
/// ```
public struct APISourcePriorityConfiguration: Sendable {
    public let preferredSource: APISource
    public let scriptPriorities: [String: ScriptAPIPriority]

    public init(
        preferredAPI: PreferredAPI = .musicbrainz,
        scriptPriorities: [String: ScriptAPIPriority] = [:]
    ) {
        self.preferredSource = Self.source(for: preferredAPI)
        self.scriptPriorities = scriptPriorities
    }

    public init(configuration: AppConfiguration) {
        self.init(
            preferredAPI: configuration.yearRetrieval.preferredAPI,
            scriptPriorities: configuration.yearRetrieval.scriptAPIPriorities
        )
    }

    func orderedSources(artist: String, album: String) -> [APISource] {
        let queryScript = dominantScript(of: "\(artist) \(album)")
        let scriptOrder = scriptPriorities[queryScript.rawValue]
            .map { Self.sources(from: $0.primary + $0.fallback) } ?? []
        return Self.uniqued(scriptOrder + defaultOrder)
    }

    private var defaultOrder: [APISource] {
        Self.uniqued([preferredSource, .musicBrainz, .discogs, .itunes])
    }

    private static func source(for preferredAPI: PreferredAPI) -> APISource {
        switch preferredAPI {
        case .musicbrainz: .musicBrainz
        case .discogs: .discogs
        case .itunes: .itunes
        }
    }

    private static func sources(from values: [String]) -> [APISource] {
        values.compactMap { value in
            switch value.lowercased().replacingOccurrences(of: "_", with: "") {
            case "musicbrainz", "mb": .musicBrainz
            case "discogs": .discogs
            case "itunes", "applemusic", "apple": .itunes
            default: nil
            }
        }
    }

    private static func uniqued(_ sources: [APISource]) -> [APISource] {
        var seen: Set<APISource> = []
        return sources.filter { source in
            seen.insert(source).inserted
        }
    }
}

public actor APIOrchestrator {
    private let musicBrainz: any ExternalAPIService
    private let discogs: any ExternalAPIService
    private let appleMusic: any ExternalAPIService
    private let reachability: NetworkReachabilityMonitor?
    private let cache: (any CacheService)?
    private let timeout: Duration
    private let maxConcurrentSourceCalls: Int
    private let sourcePriorityConfiguration: APISourcePriorityConfiguration
    private let log = AppLogger.api

    /// Creates an orchestrator with three API sources and a per-source timeout.
    ///
    /// - Parameters:
    ///   - musicBrainz: MusicBrainz API client.
    ///   - discogs: Discogs API client.
    ///   - appleMusic: Apple Music catalog search client.
    ///   - reachability: Optional network monitor. When offline, API calls are skipped.
    ///   - cache: Optional persistent cache for successful source results.
    ///   - timeout: Maximum time to wait for each source. Defaults to 15 seconds.
    ///   - maxConcurrentSourceCalls: Maximum API sources queried at once. Values below 1 are clamped.
    ///   - sourcePriorityConfiguration: Preferred source ordering and tie-break configuration.
    public init(
        musicBrainz: any ExternalAPIService,
        discogs: any ExternalAPIService,
        appleMusic: any ExternalAPIService,
        reachability: NetworkReachabilityMonitor? = nil,
        cache: (any CacheService)? = nil,
        timeout: Duration = .seconds(15),
        maxConcurrentSourceCalls: Int = 3,
        sourcePriorityConfiguration: APISourcePriorityConfiguration = APISourcePriorityConfiguration()
    ) {
        self.musicBrainz = musicBrainz
        self.discogs = discogs
        self.appleMusic = appleMusic
        self.reachability = reachability
        self.cache = cache
        self.timeout = timeout
        self.maxConcurrentSourceCalls = max(1, maxConcurrentSourceCalls)
        self.sourcePriorityConfiguration = sourcePriorityConfiguration
    }

    /// Query configured sources and aggregate results by year score.
    ///
    /// Each source runs independently with its own timeout. If a source fails
    /// or exceeds the timeout, the orchestrator continues with remaining results.
    /// The year with the highest combined confidence score wins.
    ///
    /// - Parameters:
    ///   - artist: Artist name to search for.
    ///   - album: Album name to search for.
    ///   - currentLibraryYear: Year currently set in the user's library.
    ///   - earliestTrackAddedYear: Earliest year any track from this album was added.
    /// - Returns: Aggregated `YearResult` with combined scores from all responding sources.
    public func getAlbumYear(
        artist: String,
        album: String,
        currentLibraryYear: Int?,
        earliestTrackAddedYear: Int?
    ) async -> YearResult {
        if let reachability, await !reachability.isConnected {
            log.info("Skipping API calls: network offline")
            return YearResult()
        }

        let signpostState = AppSignpost.apiCall.beginInterval("orchestrateAlbumYear")
        defer { AppSignpost.apiCall.endInterval("orchestrateAlbumYear", signpostState) }

        let serviceBySource: [APISource: any ExternalAPIService] = [
            .musicBrainz: musicBrainz,
            .discogs: discogs,
            .itunes: appleMusic,
        ]
        let orderedSources = sourcePriorityConfiguration.orderedSources(artist: artist, album: album)
        let sources = orderedSources.compactMap { source -> (source: APISource, service: any ExternalAPIService)? in
            guard let service = serviceBySource[source] else { return nil }
            return (source, service)
        }
        let query = SourceQuery(
            artist: artist,
            album: album,
            currentLibraryYear: currentLibraryYear,
            earliestTrackAddedYear: earliestTrackAddedYear,
            timeout: timeout
        )

        let results = await fetchSourceResults(sources: sources, query: query)

        return Self.aggregateResults(results, orderedSources: orderedSources)
    }

    // MARK: - Private

    /// Fetches source results with bounded concurrency while preserving configured source order.
    private func fetchSourceResults(
        sources: [(source: APISource, service: any ExternalAPIService)],
        query: SourceQuery
    ) async -> [SourceFetchResult] {
        await withTaskGroup(
            of: SourceFetchResult.self,
            returning: [SourceFetchResult].self
        ) { group in
            var nextSourceIndex = 0
            let initialSourceCount = min(maxConcurrentSourceCalls, sources.count)

            while nextSourceIndex < initialSourceCount {
                addSourceTask(
                    to: &group,
                    sourceEntry: sources[nextSourceIndex],
                    query: query,
                    cache: cache
                )
                nextSourceIndex += 1
            }

            var collected: [SourceFetchResult] = []
            while let result = await group.next() {
                collected.append(result)

                if nextSourceIndex < sources.count {
                    addSourceTask(
                        to: &group,
                        sourceEntry: sources[nextSourceIndex],
                        query: query,
                        cache: cache
                    )
                    nextSourceIndex += 1
                }
            }
            return collected
        }
    }

    private func addSourceTask(
        to group: inout TaskGroup<SourceFetchResult>,
        sourceEntry: (source: APISource, service: any ExternalAPIService),
        query: SourceQuery,
        cache: (any CacheService)?
    ) {
        let log = log
        let (source, service) = sourceEntry
        group.addTask {
            await Self.cachedOrFetchedResult(
                source: source,
                service: service,
                query: query,
                cache: cache,
                log: log
            )
        }
    }

    private static func cachedOrFetchedResult(
        source: APISource,
        service: any ExternalAPIService,
        query: SourceQuery,
        cache: (any CacheService)?,
        log: Logger
    ) async -> SourceFetchResult {
        if let cached = await cachedAPIResult(source: source, query: query, cache: cache) {
            return SourceFetchResult(source: source, result: cached)
        }

        let result = await fetchWithTimeout(
            source: source,
            service: service,
            query: query,
            log: log
        )

        await cacheAPIResult(result, source: source, query: query, cache: cache)
        return SourceFetchResult(source: source, result: result)
    }

    private static func cachedAPIResult(
        source: APISource,
        query: SourceQuery,
        cache: (any CacheService)?
    ) async -> YearResult? {
        guard let cached = await cache?.getCachedAPIResult(
            artist: query.artist,
            album: query.album,
            source: source.rawValue
        ),
            let year = cached.year
        else {
            return nil
        }

        let confidence = cached.metadata["confidence"].flatMap(Int.init) ?? 0
        let rawScore = cached.metadata["rawScore"].flatMap(Int.init) ?? confidence
        let isDefinitive = cached.metadata["isDefinitive"].flatMap(Bool.init) ?? false

        return YearResult(
            year: year,
            isDefinitive: isDefinitive,
            confidence: confidence,
            rawScore: rawScore,
            yearScores: [year: confidence]
        )
    }

    private static func cacheAPIResult(
        _ result: YearResult,
        source: APISource,
        query: SourceQuery,
        cache: (any CacheService)?
    ) async {
        guard let year = result.year else { return }

        await cache?.setCachedAPIResult(CachedAPIResult(
            artist: query.artist,
            album: query.album,
            year: year,
            source: source.rawValue,
            timestamp: .now,
            ttl: nil,
            metadata: [
                "confidence": String(result.confidence),
                "rawScore": String(result.rawScore),
                "isDefinitive": String(result.isDefinitive),
            ]
        ))
    }

    private static func fetchWithTimeout(
        source: APISource,
        service: any ExternalAPIService,
        query: SourceQuery,
        log: Logger
    ) async -> YearResult {
        do {
            return try await withThrowingTaskGroup(
                of: YearResult.self
            ) { group in
                group.addTask {
                    try await service.getAlbumYear(
                        artist: query.artist,
                        album: query.album,
                        currentLibraryYear: query.currentLibraryYear,
                        earliestTrackAddedYear: query.earliestTrackAddedYear
                    )
                }

                group.addTask {
                    try await Task.sleep(for: query.timeout)
                    throw OrchestratorTimeoutError()
                }

                // Race: group.next() returns whichever task finishes first.
                // If the API call wins, we get the result; if the sleep timer
                // wins, it throws OrchestratorTimeoutError caught below.
                guard let result = try await group.next() else {
                    return YearResult()
                }

                group.cancelAll()
                return result
            }
        } catch is OrchestratorTimeoutError {
            log.warning("\(source.rawValue, privacy: .public) timed out after \(query.timeout, privacy: .public)")
            return YearResult()
        } catch is CancellationError {
            log.debug("\(source.rawValue, privacy: .public) cancelled")
            return YearResult()
        } catch {
            log.error("\(source.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return YearResult()
        }
    }

    /// Combines year scores from all source results and selects the best year.
    ///
    /// Merges `yearScores` dictionaries additively. The year with the highest
    /// combined score wins. `isDefinitive` is true when 2+ sources agree on
    /// the same year. Final confidence is capped at 100.
    private static func aggregateResults(
        _ results: [SourceFetchResult],
        orderedSources: [APISource]
    ) -> YearResult {
        var combinedScores: [Int: Int] = [:]

        for result in results.map(\.result) {
            for (year, score) in result.yearScores {
                combinedScores[year, default: 0] += score
            }
        }

        guard let bestScore = combinedScores.values.max() else {
            return YearResult()
        }

        let sourceRank = Dictionary(uniqueKeysWithValues: orderedSources.enumerated().map { ($0.element, $0.offset) })
        let bestYear = combinedScores
            .filter { $0.value == bestScore }
            .keys
            .min { lhs, rhs in
                let lhsRank = bestSourceRank(for: lhs, in: results, sourceRank: sourceRank)
                let rhsRank = bestSourceRank(for: rhs, in: results, sourceRank: sourceRank)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs < rhs
            }

        guard let bestYear else {
            return YearResult()
        }

        let agreeingSourceCount = results.count(where: { $0.result.year == bestYear })
        let isDefinitive = agreeingSourceCount >= 2

        return YearResult(
            year: bestYear,
            isDefinitive: isDefinitive,
            confidence: min(bestScore, 100),
            yearScores: combinedScores
        )
    }

    private static func bestSourceRank(
        for year: Int,
        in results: [SourceFetchResult],
        sourceRank: [APISource: Int]
    ) -> Int {
        results
            .filter { $0.result.year == year || $0.result.yearScores[year] != nil }
            .compactMap { sourceRank[$0.source] }
            .min() ?? Int.max
    }
}

// MARK: - SourceQuery

/// Bundles query parameters for a single source fetch.
private struct SourceQuery {
    let artist: String
    let album: String
    let currentLibraryYear: Int?
    let earliestTrackAddedYear: Int?
    let timeout: Duration
}

private struct SourceFetchResult {
    let source: APISource
    let result: YearResult
}

// MARK: - OrchestratorTimeoutError

/// Internal error used to distinguish timeout from other failures.
private struct OrchestratorTimeoutError: Error {}
