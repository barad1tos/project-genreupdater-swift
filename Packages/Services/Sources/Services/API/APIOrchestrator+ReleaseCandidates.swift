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

        let fetched = await withTaskGroup(
            of: (source: APISource, candidates: [ReleaseCandidate]).self,
            returning: [(source: APISource, candidates: [ReleaseCandidate])].self
        ) { group in
            for sourceEntry in sources {
                group.addTask {
                    let candidates = await fetchReleaseCandidatesWithTimeout(
                        sourceEntry: sourceEntry,
                        query: query,
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

private func fetchReleaseCandidatesWithTimeout(
    sourceEntry: (source: APISource, service: any ExternalAPIService),
    query: ReleaseCandidateQuery,
    apiRetryConfiguration: APIRetryConfiguration,
    log: Logger
) async -> [ReleaseCandidate] {
    do {
        return try await withThrowingTaskGroup(
            of: [ReleaseCandidate].self,
            returning: [ReleaseCandidate].self
        ) { group in
            group.addTask {
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
    } catch is ReleaseCandidateTimeoutError {
        log
            .warning(
                "\(sourceEntry.source.rawValue, privacy: .public) candidate fetch timed out after \(query.timeout, privacy: .public)"
            )
        return []
    } catch is CancellationError {
        log.debug("\(sourceEntry.source.rawValue, privacy: .public) candidate fetch cancelled")
        return []
    } catch {
        log
            .error(
                "\(sourceEntry.source.rawValue, privacy: .public) candidate fetch failed: \(error.localizedDescription, privacy: .public)"
            )
        return []
    }
}

private struct ReleaseCandidateQuery {
    let artist: String
    let album: String
    let currentLibraryYear: Int?
    let earliestTrackAddedYear: Int?
    let timeout: Duration
}

private struct ReleaseCandidateTimeoutError: Error {}
