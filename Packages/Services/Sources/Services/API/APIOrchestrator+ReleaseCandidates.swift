// APIOrchestrator+ReleaseCandidates.swift — Raw release candidate collection

import Core
import Foundation
import OSLog

extension APIOrchestrator {
    /// Fetch raw release candidates from configured API sources in priority order.
    ///
    /// Candidate fetching mirrors album-year source ordering but does not write
    /// source results into `YearResult` cache. `YearDeterminator` owns scoring
    /// and fallback decisions for these values.
    public func getReleaseCandidates(
        artist: String,
        album: String,
        currentLibraryYear: Int?,
        earliestTrackAddedYear: Int?
    ) async -> [ReleaseCandidate] {
        let log = AppLogger.api
        if let reachability, await !reachability.isConnected {
            log.info("Skipping API candidate calls: network offline")
            return []
        }

        let serviceBySource: [APISource: any ExternalAPIService] = [
            .musicBrainz: musicBrainz,
            .discogs: discogs,
            .itunes: appleMusic,
        ]
        let orderedSources = sourcePriorityConfiguration.orderedSources(artist: artist, album: album)
        let activeSources = orderedSources.filter { !disabledSources.contains($0) }
        let sources = activeSources.compactMap { source -> (source: APISource, service: any ExternalAPIService)? in
            guard let service = serviceBySource[source] else { return nil }
            return (source, service)
        }
        let query = ReleaseCandidateQuery(
            artist: artist,
            album: album,
            currentLibraryYear: currentLibraryYear,
            earliestTrackAddedYear: earliestTrackAddedYear,
            timeout: timeout
        )
        let sourceRank = Dictionary(uniqueKeysWithValues: activeSources.enumerated().map { ($0.element, $0.offset) })
        let apiRetryConfiguration = apiRetryConfiguration
        let cacheContext = ReleaseCandidateCacheContext(
            cache: cache,
            positiveResultTTL: candidateResultTTL,
            negativeResultTTL: negativeResultTTL
        )

        let fetched = await withTaskGroup(
            of: (source: APISource, candidates: [ReleaseCandidate]).self,
            returning: [(source: APISource, candidates: [ReleaseCandidate])].self
        ) { group in
            for sourceEntry in sources {
                group.addTask {
                    let candidates = await cachedOrFetchedReleaseCandidates(
                        sourceEntry: sourceEntry,
                        query: query,
                        cacheContext: cacheContext,
                        apiRetryConfiguration: apiRetryConfiguration,
                        log: log
                    )
                    return (sourceEntry.source, candidates)
                }
            }

            var collected: [(source: APISource, candidates: [ReleaseCandidate])] = []
            while let result = await group.next() {
                collected.append(result)
            }
            return collected
        }

        return fetched
            .sorted { (sourceRank[$0.source] ?? Int.max) < (sourceRank[$1.source] ?? Int.max) }
            .flatMap(\.candidates)
    }
}

private func cachedOrFetchedReleaseCandidates(
    sourceEntry: (source: APISource, service: any ExternalAPIService),
    query: ReleaseCandidateQuery,
    cacheContext: ReleaseCandidateCacheContext,
    apiRetryConfiguration: APIRetryConfiguration,
    log: Logger
) async -> [ReleaseCandidate] {
    if let cached = await cachedReleaseCandidates(
        source: sourceEntry.source,
        query: query,
        cache: cacheContext.cache
    ) {
        return cached
    }

    let outcome = await fetchReleaseCandidatesWithTimeout(
        sourceEntry: sourceEntry,
        query: query,
        apiRetryConfiguration: apiRetryConfiguration,
        log: log
    )

    await cacheReleaseCandidates(
        outcome.candidates,
        source: sourceEntry.source,
        query: query,
        cacheContext: cacheContext,
        shouldCacheEmptyResult: outcome.shouldCacheEmptyResult
    )
    return outcome.candidates
}

private func fetchReleaseCandidatesWithTimeout(
    sourceEntry: (source: APISource, service: any ExternalAPIService),
    query: ReleaseCandidateQuery,
    apiRetryConfiguration: APIRetryConfiguration,
    log: Logger
) async -> ReleaseCandidateFetchOutcome {
    do {
        let candidates = try await withThrowingTaskGroup(
            of: [ReleaseCandidate].self,
            returning: [ReleaseCandidate].self
        ) { group in
            group.addTask {
                try await fetchReleaseCandidatesWithRetry(
                    sourceEntry: sourceEntry,
                    query: query,
                    apiRetryConfiguration: apiRetryConfiguration
                )
            }

            group.addTask {
                try await Task.sleep(for: query.timeout)
                throw ReleaseCandidateTimeoutError()
            }

            guard let candidates = try await group.next() else {
                return []
            }

            group.cancelAll()
            return candidates
        }
        return ReleaseCandidateFetchOutcome(candidates: candidates, shouldCacheEmptyResult: true)
    } catch is ReleaseCandidateTimeoutError {
        log
            .warning(
                "\(sourceEntry.source.rawValue, privacy: .public) candidate fetch timed out after \(query.timeout, privacy: .public)"
            )
        return ReleaseCandidateFetchOutcome(candidates: [], shouldCacheEmptyResult: false)
    } catch is CancellationError {
        log.debug("\(sourceEntry.source.rawValue, privacy: .public) candidate fetch cancelled")
        return ReleaseCandidateFetchOutcome(candidates: [], shouldCacheEmptyResult: false)
    } catch {
        log
            .error(
                "\(sourceEntry.source.rawValue, privacy: .public) candidate fetch failed: \(error.localizedDescription, privacy: .public)"
            )
        return ReleaseCandidateFetchOutcome(candidates: [], shouldCacheEmptyResult: false)
    }
}

private func fetchReleaseCandidatesWithRetry(
    sourceEntry: (source: APISource, service: any ExternalAPIService),
    query: ReleaseCandidateQuery,
    apiRetryConfiguration: APIRetryConfiguration
) async throws -> [ReleaseCandidate] {
    try await withRetry(
        maxAttempts: apiRetryConfiguration.maxAttempts,
        initialDelay: apiRetryConfiguration.initialDelay
    ) {
        try await sourceEntry.service.getReleaseCandidates(
            artist: query.artist,
            album: query.album,
            currentLibraryYear: query.currentLibraryYear,
            earliestTrackAddedYear: query.earliestTrackAddedYear
        )
    }
}

private func cachedReleaseCandidates(
    source: APISource,
    query: ReleaseCandidateQuery,
    cache: (any CacheService)?
) async -> [ReleaseCandidate]? {
    let cacheKey = releaseCandidateCacheKey(source: source, query: query)
    let cachedEntries: [CachedReleaseCandidate]? = await cache?.get(key: cacheKey)
    return cachedEntries?.map(\.releaseCandidate)
}

private func cacheReleaseCandidates(
    _ candidates: [ReleaseCandidate],
    source: APISource,
    query: ReleaseCandidateQuery,
    cacheContext: ReleaseCandidateCacheContext,
    shouldCacheEmptyResult: Bool
) async {
    if candidates.isEmpty, !shouldCacheEmptyResult {
        return
    }

    let cacheKey = releaseCandidateCacheKey(source: source, query: query)
    let ttl = candidates.isEmpty ? cacheContext.negativeResultTTL : cacheContext.positiveResultTTL
    await cacheContext.cache?.set(
        key: cacheKey,
        value: candidates.map(CachedReleaseCandidate.init),
        ttl: ttl
    )
}

private func releaseCandidateCacheKey(source: APISource, query: ReleaseCandidateQuery) -> String {
    [
        "release_candidates",
        source.rawValue,
        normalizeForMatching(query.artist),
        normalizeForMatching(query.album),
    ].joined(separator: ":")
}

private struct ReleaseCandidateQuery {
    let artist: String
    let album: String
    let currentLibraryYear: Int?
    let earliestTrackAddedYear: Int?
    let timeout: Duration
}

private struct ReleaseCandidateCacheContext {
    let cache: (any CacheService)?
    let positiveResultTTL: TimeInterval?
    let negativeResultTTL: TimeInterval
}

private struct ReleaseCandidateFetchOutcome {
    let candidates: [ReleaseCandidate]
    let shouldCacheEmptyResult: Bool
}

private struct CachedReleaseCandidate: Codable {
    let artist: String
    let album: String
    let year: Int
    let source: APISource
    let releaseType: ReleaseType
    let status: ReleaseStatus
    let country: String?
    let isReissue: Bool
    let mbReleaseGroupID: String?
    let mbReleaseGroupFirstYear: Int?
    let genre: String?

    init(_ candidate: ReleaseCandidate) {
        artist = candidate.artist
        album = candidate.album
        year = candidate.year
        source = candidate.source
        releaseType = candidate.releaseType
        status = candidate.status
        country = candidate.country
        isReissue = candidate.isReissue
        mbReleaseGroupID = candidate.mbReleaseGroupID
        mbReleaseGroupFirstYear = candidate.mbReleaseGroupFirstYear
        genre = candidate.genre
    }

    var releaseCandidate: ReleaseCandidate {
        ReleaseCandidate(
            artist: artist,
            album: album,
            year: year,
            source: source,
            releaseType: releaseType,
            status: status,
            country: country,
            isReissue: isReissue,
            mbReleaseGroupID: mbReleaseGroupID,
            mbReleaseGroupFirstYear: mbReleaseGroupFirstYear,
            genre: genre
        )
    }
}

private struct ReleaseCandidateTimeoutError: Error {}
