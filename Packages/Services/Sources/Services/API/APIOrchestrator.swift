// APIOrchestrator.swift — Parallel multi-source API coordinator
// Phase 4: API + Cache

import Core
import Foundation
import OSLog

// MARK: - APIOrchestrator

/// Stores the preferred API source and script-specific priority configuration.
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
        let scriptOrder = (scriptPriorities[queryScript.rawValue] ?? scriptPriorities["default"])
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

public struct APIOrchestratorServices: Sendable {
    let musicBrainz: any ExternalAPIService
    let discogs: any ExternalAPIService
    let appleMusic: any ExternalAPIService

    public init(
        musicBrainz: any ExternalAPIService,
        discogs: any ExternalAPIService,
        appleMusic: any ExternalAPIService
    ) {
        self.musicBrainz = musicBrainz
        self.discogs = discogs
        self.appleMusic = appleMusic
    }
}

public struct APIOrchestratorConfiguration: Sendable {
    public var reachability: NetworkReachabilityMonitor?
    public var cache: (any CacheService)?
    public var pendingVerificationService: (any PendingVerificationService)?
    public var maxVerificationAttempts: Int
    public var timeout: Duration
    public var negativeResultTTL: TimeInterval
    public var candidateResultTTL: TimeInterval?
    public var disabledSources: Set<APISource>
    public var maxConcurrentSourceCalls: Int
    public var maxAPIRetries: Int
    public var apiRetryDelaySeconds: Double
    public var sourcePriorityConfiguration: APISourcePriorityConfiguration
    public var soundtrackPatterns: [String]
    public var variousArtistsNames: [String]
    public var discogsReissueKeywords: [String]
    public var discogsSearchConfiguration: DiscogsSearchConfig
    public var dateProvider: @Sendable () -> Date

    public init() {
        reachability = nil
        cache = nil
        pendingVerificationService = nil
        maxVerificationAttempts = FallbackConfig().maxVerificationAttempts
        timeout = .seconds(15)
        negativeResultTTL = CachingConfig().negativeResultTTL
        candidateResultTTL = nil
        dateProvider = { Date() }
        disabledSources = []
        maxConcurrentSourceCalls = 3
        maxAPIRetries = 0
        apiRetryDelaySeconds = 1
        sourcePriorityConfiguration = APISourcePriorityConfiguration()
        soundtrackPatterns = SearchStrategyDefaults.soundtrackPatterns
        variousArtistsNames = SearchStrategyDefaults.variousArtistsNames
        discogsReissueKeywords = MetadataRuleDefaults.releaseReissues
        discogsSearchConfiguration = DiscogsSearchConfig()
    }

    /// Maps every config-derived field from `AppConfiguration`.
    ///
    /// Only the runtime service references (`reachability`, `cache`,
    /// `pendingVerificationService`) and `disabledSources` are left for the
    /// composition root to inject when available.
    public init(configuration: AppConfiguration) {
        self.init()
        maxVerificationAttempts = configuration.yearRetrieval.fallback.maxVerificationAttempts
        negativeResultTTL = configuration.caching.negativeResultTTL
        candidateResultTTL = GRDBCacheService.resolvedAPIResultTTL(configuration: configuration)
        maxConcurrentSourceCalls = configuration.yearRetrieval.rateLimits.concurrentAPICalls
        maxAPIRetries = configuration.runtime.maxRetries
        apiRetryDelaySeconds = configuration.runtime.retryDelaySeconds
        sourcePriorityConfiguration = APISourcePriorityConfiguration(configuration: configuration)
        soundtrackPatterns = configuration.albumTypeDetection.soundtrackPatterns
        variousArtistsNames = configuration.albumTypeDetection.variousArtistsNames
        discogsReissueKeywords = configuration.yearRetrieval.reissueDetection.reissueKeywords
        discogsSearchConfiguration = configuration.yearRetrieval.discogsSearch
    }
}

struct APISearchQuery {
    let artist: String
    let album: String
}

struct PendingAlbumYearLookup {
    let result: YearResult
    let didAttemptLookup: Bool
}

func makeAPISearchQuery(artist: String, album: String) -> APISearchQuery {
    let albumWithoutQuotes = album
        .replacingOccurrences(of: "\"", with: "")
        .replacingOccurrences(of: "'", with: "")
    let albumWithoutParentheticalText = stripParentheticalText(from: albumWithoutQuotes)
    return APISearchQuery(
        artist: normalizeAPIQueryName(artist),
        album: normalizeAPIQueryName(albumWithoutParentheticalText)
    )
}

public actor APIOrchestrator {
    let musicBrainz: any ExternalAPIService
    let discogs: any ExternalAPIService
    let appleMusic: any ExternalAPIService
    let reachability: NetworkReachabilityMonitor?
    let cache: (any CacheService)?
    private let pendingVerificationService: (any PendingVerificationService)?
    private let maxVerificationAttempts: Int
    let timeout: Duration
    let negativeResultTTL: TimeInterval
    let candidateResultTTL: TimeInterval?
    nonisolated public let disabledSources: Set<APISource>
    let providerAdmission: ProviderAdmission
    let apiRetryConfiguration: APIRetryConfiguration
    let sourcePriorityConfiguration: APISourcePriorityConfiguration
    let soundtrackPatterns: [String]
    let variousArtistsNames: [String]
    let discogsReissueKeywords: [String]
    let discogsSearchConfiguration: DiscogsSearchConfig
    let dateProvider: @Sendable () -> Date
    private let log = AppLogger.api

    /// Creates an orchestrator with three API sources and a per-source timeout.
    ///
    /// - Parameters:
    ///   - services: Music metadata API clients.
    ///   - configuration: Runtime limits, cache policy, and source ordering.
    public init(
        services: APIOrchestratorServices,
        configuration: APIOrchestratorConfiguration = APIOrchestratorConfiguration()
    ) {
        musicBrainz = services.musicBrainz
        discogs = services.discogs
        appleMusic = services.appleMusic
        reachability = configuration.reachability
        cache = configuration.cache
        pendingVerificationService = configuration.pendingVerificationService
        maxVerificationAttempts = max(0, configuration.maxVerificationAttempts)
        timeout = configuration.timeout
        negativeResultTTL = max(0, configuration.negativeResultTTL)
        candidateResultTTL = configuration.candidateResultTTL.flatMap { $0 > 0 ? $0 : nil }
        disabledSources = configuration.disabledSources
        providerAdmission = ProviderAdmission(limit: configuration.maxConcurrentSourceCalls)
        soundtrackPatterns = configuration.soundtrackPatterns
        variousArtistsNames = configuration.variousArtistsNames
        discogsReissueKeywords = configuration.discogsReissueKeywords
        discogsSearchConfiguration = configuration.discogsSearchConfiguration
        dateProvider = configuration.dateProvider
        apiRetryConfiguration = APIRetryConfiguration(
            maxRetries: configuration.maxAPIRetries,
            delaySeconds: configuration.apiRetryDelaySeconds
        )
        sourcePriorityConfiguration = configuration.sourcePriorityConfiguration
    }

    /// Creates an orchestrator from concrete API clients and optional runtime configuration.
    public init(
        musicBrainz: any ExternalAPIService,
        discogs: any ExternalAPIService,
        appleMusic: any ExternalAPIService,
        configuration: APIOrchestratorConfiguration = APIOrchestratorConfiguration()
    ) {
        self.init(
            services: APIOrchestratorServices(
                musicBrainz: musicBrainz,
                discogs: discogs,
                appleMusic: appleMusic
            ),
            configuration: configuration
        )
    }

    /// Creates an orchestrator with common runtime overrides kept source-compatible with older call sites.
    public init(
        musicBrainz: any ExternalAPIService,
        discogs: any ExternalAPIService,
        appleMusic: any ExternalAPIService,
        reachability: NetworkReachabilityMonitor? = nil,
        cache: (any CacheService)? = nil,
        timeout: Duration = .seconds(15),
        disabledSources: Set<APISource> = []
    ) {
        var configuration = APIOrchestratorConfiguration()
        configuration.reachability = reachability
        configuration.cache = cache
        configuration.timeout = timeout
        configuration.disabledSources = disabledSources
        self.init(
            musicBrainz: musicBrainz,
            discogs: discogs,
            appleMusic: appleMusic,
            configuration: configuration
        )
    }

    /// Query configured sources and aggregate results by year score.
    ///
    /// Uncached provider calls share the orchestrator-wide admission limit. One
    /// caller timeout races permit wait, retries, and provider execution; cache
    /// hits bypass admission. A timed-out non-cooperative provider retains its
    /// permit until it exits. Failed or timed-out sources are excluded from aggregation.
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
        earliestTrackAddedYear: Int?,
        pendingRemovalAliases: [(artist: String, album: String)] = []
    ) async -> YearResult {
        let lookup = await getAlbumYearInternal(
            artist: artist,
            album: album,
            currentLibraryYear: currentLibraryYear,
            earliestTrackAddedYear: earliestTrackAddedYear,
            pendingRemovalAliases: pendingRemovalAliases
        )
        return lookup.result
    }

    func getAlbumYearForPendingVerification(
        artist: String,
        album: String,
        currentLibraryYear: Int?,
        earliestTrackAddedYear: Int?
    ) async -> PendingAlbumYearLookup {
        await getAlbumYearInternal(
            artist: artist,
            album: album,
            currentLibraryYear: currentLibraryYear,
            earliestTrackAddedYear: earliestTrackAddedYear,
            pendingRemovalAliases: nil
        )
    }

    private func getAlbumYearInternal(
        artist: String,
        album: String,
        currentLibraryYear: Int?,
        earliestTrackAddedYear: Int?,
        pendingRemovalAliases: [(artist: String, album: String)]?
    ) async -> PendingAlbumYearLookup {
        if let reachability, await !reachability.isConnected {
            log.info("Skipping API calls: network offline")
            return PendingAlbumYearLookup(result: YearResult(), didAttemptLookup: false)
        }

        let signpostState = AppSignpost.apiCall.beginInterval("orchestrateAlbumYear")
        defer { AppSignpost.apiCall.endInterval("orchestrateAlbumYear", signpostState) }

        let serviceBySource: [APISource: any ExternalAPIService] = [
            .musicBrainz: musicBrainz,
            .discogs: discogs,
            .itunes: appleMusic,
        ]
        let searchQuery = makeAPISearchQuery(artist: artist, album: album)
        let orderedSources = sourcePriorityConfiguration.orderedSources(
            artist: searchQuery.artist,
            album: searchQuery.album
        )
        let activeSources = orderedSources.filter { !disabledSources.contains($0) }
        let sources = activeSources.compactMap { source -> (source: APISource, service: any ExternalAPIService)? in
            guard let service = serviceBySource[source] else { return nil }
            return (source, service)
        }
        let query = SourceQuery(
            artist: searchQuery.artist,
            album: searchQuery.album,
            currentLibraryYear: currentLibraryYear,
            earliestTrackAddedYear: earliestTrackAddedYear,
            timeout: timeout
        )

        let results = await fetchSourceResults(sources: sources, query: query)
        guard !Task.isCancelled else {
            return PendingAlbumYearLookup(result: YearResult(), didAttemptLookup: false)
        }
        let apiResult = Self.aggregateResults(results, orderedSources: activeSources)
        let isConfirmedMiss = !results.isEmpty && results.allSatisfy(\.didCompleteLookup)
        if apiResult.year == nil, !isConfirmedMiss {
            let result = Self.applyingCurrentLibraryFallback(
                to: apiResult,
                currentLibraryYear: currentLibraryYear,
                earliestTrackAddedYear: earliestTrackAddedYear
            )
            return PendingAlbumYearLookup(result: result, didAttemptLookup: false)
        }
        if let pendingRemovalAliases {
            await PendingVerificationSync.synchronize(
                service: pendingVerificationService,
                albumKey: (artist, album),
                albumAliases: pendingRemovalAliases,
                currentLibraryYear: currentLibraryYear,
                maxVerificationAttempts: maxVerificationAttempts,
                result: apiResult
            )
        }
        let result = Self.applyingCurrentLibraryFallback(
            to: apiResult,
            currentLibraryYear: currentLibraryYear,
            earliestTrackAddedYear: earliestTrackAddedYear
        )
        return PendingAlbumYearLookup(result: result, didAttemptLookup: true)
    }

    // MARK: - Private

    private static func applyingCurrentLibraryFallback(
        to result: YearResult,
        currentLibraryYear: Int?,
        earliestTrackAddedYear: Int?
    ) -> YearResult {
        guard result.year == nil,
              let fallbackYear = currentLibraryYear
        else {
            return result
        }

        let currentYear = Calendar.current.component(.year, from: Date())
        guard isValidCurrentLibraryFallbackYear(fallbackYear, currentYear: currentYear),
              !isCurrentYearContamination(
                  currentLibraryYear: fallbackYear,
                  earliestTrackAddedYear: earliestTrackAddedYear,
                  currentYear: currentYear
              )
        else {
            return result
        }

        return YearResult(year: fallbackYear)
    }

    private static func isValidCurrentLibraryFallbackYear(_ year: Int, currentYear: Int) -> Bool {
        year >= YearLogicConfig().minValidYear && year <= currentYear
    }

    private static func isCurrentYearContamination(
        currentLibraryYear: Int,
        earliestTrackAddedYear: Int?,
        currentYear: Int
    ) -> Bool {
        guard currentLibraryYear == currentYear else {
            return false
        }

        guard let earliestTrackAddedYear else {
            return true
        }

        return earliestTrackAddedYear > currentYear || earliestTrackAddedYear < currentYear
    }

    /// Fetches source results concurrently; aggregation applies configured source priority separately.
    private func fetchSourceResults(
        sources: [(source: APISource, service: any ExternalAPIService)],
        query: SourceQuery
    ) async -> [SourceFetchResult] {
        let cacheContext = SourceCacheContext(
            cache: cache,
            negativeResultTTL: negativeResultTTL,
            candidateResultTTL: candidateResultTTL,
            discogsAcquisitionSignature: DiscogsAcquisition.signature(for: discogsSearchConfiguration)
        )

        return await withTaskGroup(
            of: SourceFetchResult.self,
            returning: [SourceFetchResult].self
        ) { group in
            for sourceEntry in sources {
                addSourceTask(
                    to: &group,
                    sourceEntry: sourceEntry,
                    query: query,
                    cacheContext: cacheContext
                )
            }

            var collected: [SourceFetchResult] = []
            while let result = await group.next() {
                collected.append(result)
            }
            return collected
        }
    }

    private func addSourceTask(
        to group: inout TaskGroup<SourceFetchResult>,
        sourceEntry: (source: APISource, service: any ExternalAPIService),
        query: SourceQuery,
        cacheContext: SourceCacheContext
    ) {
        let apiRetryConfiguration = apiRetryConfiguration
        let providerAdmission = providerAdmission
        group.addTask {
            await Self.cachedOrFetchedResult(
                sourceEntry: sourceEntry,
                query: query,
                cacheContext: cacheContext,
                apiRetryConfiguration: apiRetryConfiguration,
                providerAdmission: providerAdmission
            )
        }
    }

    private static func cachedOrFetchedResult(
        sourceEntry: (source: APISource, service: any ExternalAPIService),
        query: SourceQuery,
        cacheContext: SourceCacheContext,
        apiRetryConfiguration: APIRetryConfiguration,
        providerAdmission: ProviderAdmission
    ) async -> SourceFetchResult {
        let source = sourceEntry.source
        if let cached = await cachedAPIResult(source: source, query: query, cacheContext: cacheContext) {
            return SourceFetchResult(source: source, result: cached, didCompleteLookup: true)
        }

        let outcome = await fetchWithTimeout(
            sourceEntry: sourceEntry,
            query: query,
            apiRetryConfiguration: apiRetryConfiguration,
            providerAdmission: providerAdmission
        )

        await cacheAPIResult(
            outcome.result,
            source: source,
            query: query,
            cacheContext: cacheContext,
            shouldCacheEmptyResult: outcome.shouldCacheEmptyResult,
        )
        return SourceFetchResult(
            source: source,
            result: outcome.result,
            didCompleteLookup: outcome.didCompleteLookup
        )
    }

    private static func cachedAPIResult(
        source: APISource,
        query: SourceQuery,
        cacheContext: SourceCacheContext
    ) async -> YearResult? {
        guard let cached = await cacheContext.cache?.getCachedAPIResult(
            artist: query.artist,
            album: query.album,
            source: source.rawValue
        ) else {
            return nil
        }
        guard source != .discogs ||
            cached.metadata[DiscogsAcquisition.metadataKey] == cacheContext.discogsAcquisitionSignature else {
            return nil
        }

        guard let year = cached.year else {
            guard cacheContext.negativeResultTTL > 0,
                  Date.now.timeIntervalSince(cached.timestamp) < cacheContext.negativeResultTTL
            else {
                return nil
            }
            return YearResult()
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
        cacheContext: SourceCacheContext,
        shouldCacheEmptyResult: Bool
    ) async {
        if let year = result.year {
            await cacheContext.cache?.setCachedAPIResult(CachedAPIResult(
                artist: query.artist,
                album: query.album,
                year: year,
                source: source.rawValue,
                timestamp: .now,
                ttl: cacheContext.candidateResultTTL,
                metadata: cacheMetadata([
                    "confidence": String(result.confidence),
                    "rawScore": String(result.rawScore),
                    "isDefinitive": String(result.isDefinitive),
                ], source: source, cacheContext: cacheContext)
            ))
            return
        }

        guard shouldCacheEmptyResult else { return }

        await cacheContext.cache?.setCachedAPIResult(CachedAPIResult(
            artist: query.artist,
            album: query.album,
            year: nil,
            source: source.rawValue,
            timestamp: .now,
            ttl: cacheContext.negativeResultTTL,
            metadata: cacheMetadata([
                "cacheKind": "negative",
            ], source: source, cacheContext: cacheContext)
        ))
    }

    private static func cacheMetadata(
        _ metadata: [String: String],
        source: APISource,
        cacheContext: SourceCacheContext
    ) -> [String: String] {
        guard source == .discogs else { return metadata }
        var metadata = metadata
        metadata[DiscogsAcquisition.metadataKey] = cacheContext.discogsAcquisitionSignature
        return metadata
    }

    /// Combines source year scores and selects the best year.
    /// Merges score dictionaries additively. The year with the highest combined score wins.
    /// `isDefinitive` is true when 2+ sources agree on the same year. Final confidence is capped at 100.
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
                if lhsRank != rhsRank {
                    return lhsRank < rhsRank
                }
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

private func fetchWithTimeout(
    sourceEntry: (source: APISource, service: any ExternalAPIService),
    query: SourceQuery,
    apiRetryConfiguration: APIRetryConfiguration,
    providerAdmission: ProviderAdmission
) async -> SourceServiceOutcome {
    let log = AppLogger.api
    do {
        let result = try await providerAdmission.execute(timeout: query.timeout) {
            try await fetchAlbumYearWithRetry(
                sourceEntry: sourceEntry,
                query: query,
                apiRetryConfiguration: apiRetryConfiguration
            )
        }
        return SourceServiceOutcome(
            result: result,
            shouldCacheEmptyResult: result.year == nil,
            didCompleteLookup: true
        )
    } catch is ProviderCallTimeout {
        log
            .warning(
                "\(sourceEntry.source.rawValue, privacy: .public) timed out after \(query.timeout, privacy: .public)"
            )
        return SourceServiceOutcome(
            result: YearResult(),
            shouldCacheEmptyResult: false,
            didCompleteLookup: false
        )
    } catch is CancellationError {
        log.debug("\(sourceEntry.source.rawValue, privacy: .public) cancelled")
        return SourceServiceOutcome(
            result: YearResult(),
            shouldCacheEmptyResult: false,
            didCompleteLookup: false
        )
    } catch {
        log
            .error(
                "\(sourceEntry.source.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
        return SourceServiceOutcome(
            result: YearResult(),
            shouldCacheEmptyResult: false,
            didCompleteLookup: false
        )
    }
}

private func fetchAlbumYearWithRetry(
    sourceEntry: (source: APISource, service: any ExternalAPIService),
    query: SourceQuery,
    apiRetryConfiguration: APIRetryConfiguration
) async throws -> YearResult {
    try await withRetry(
        maxAttempts: apiRetryConfiguration.maxAttempts,
        initialDelay: apiRetryConfiguration.initialDelay
    ) {
        try await sourceEntry.service.getAlbumYear(
            artist: query.artist,
            album: query.album,
            currentLibraryYear: query.currentLibraryYear,
            earliestTrackAddedYear: query.earliestTrackAddedYear
        )
    }
}

// MARK: - SourceQuery

/// Bundles query parameters for a single source fetch.
struct APIRetryConfiguration {
    let maxAttempts: Int
    let initialDelay: Duration

    init(maxRetries: Int, delaySeconds: Double) {
        maxAttempts = max(1, max(0, maxRetries) + 1)
        initialDelay = .milliseconds(Int64((max(0, delaySeconds) * 1000).rounded()))
    }
}

private struct SourceQuery {
    let artist: String
    let album: String
    let currentLibraryYear: Int?
    let earliestTrackAddedYear: Int?
    let timeout: Duration
}

private struct SourceCacheContext {
    let cache: (any CacheService)?
    let negativeResultTTL: TimeInterval
    let candidateResultTTL: TimeInterval?
    let discogsAcquisitionSignature: String
}

private struct SourceFetchResult {
    let source: APISource
    let result: YearResult
    let didCompleteLookup: Bool
}

private struct SourceServiceOutcome {
    let result: YearResult
    let shouldCacheEmptyResult: Bool
    let didCompleteLookup: Bool
}

private func normalizeAPIQueryName(_ name: String) -> String {
    guard !name.isEmpty else { return name }

    var normalized = name
    for (oldValue, newValue) in [
        (" & ", " and "),
        ("&", " and "),
        (" w/ ", " with "),
        (" w/", " with"),
        (" = ", " "),
        (":", " "),
    ] {
        normalized = normalized.replacingOccurrences(of: oldValue, with: newValue)
    }

    if let regex = try? NSRegularExpression(pattern: "\\s*\\+\\s+\\d+.*$") {
        let range = NSRange(normalized.startIndex ..< normalized.endIndex, in: normalized)
        normalized = regex.stringByReplacingMatches(in: normalized, range: range, withTemplate: "")
    }

    if let slashRange = normalized.range(of: " / ") {
        normalized = String(normalized[..<slashRange.lowerBound])
    }

    return normalized.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

private func stripParentheticalText(from text: String) -> String {
    let pattern = "\\s*\\([^)]*\\)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let range = NSRange(text.startIndex ..< text.endIndex, in: text)
    let strippedText = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    return strippedText.trimmingCharacters(in: .whitespacesAndNewlines)
}
