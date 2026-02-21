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
public actor APIOrchestrator {
    private let musicBrainz: any ExternalAPIService
    private let discogs: any ExternalAPIService
    private let appleMusic: any ExternalAPIService
    private let reachability: NetworkReachabilityMonitor?
    private let timeout: Duration
    private let log = AppLogger.api

    /// Creates an orchestrator with three API sources and a per-source timeout.
    ///
    /// - Parameters:
    ///   - musicBrainz: MusicBrainz API client.
    ///   - discogs: Discogs API client.
    ///   - appleMusic: Apple Music catalog search client.
    ///   - reachability: Optional network monitor. When offline, API calls are skipped.
    ///   - timeout: Maximum time to wait for each source. Defaults to 15 seconds.
    public init(
        musicBrainz: any ExternalAPIService,
        discogs: any ExternalAPIService,
        appleMusic: any ExternalAPIService,
        reachability: NetworkReachabilityMonitor? = nil,
        timeout: Duration = .seconds(15)
    ) {
        self.musicBrainz = musicBrainz
        self.discogs = discogs
        self.appleMusic = appleMusic
        self.reachability = reachability
        self.timeout = timeout
    }

    /// Query all three sources in parallel and aggregate results by year score.
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


        let sources: [(name: String, service: any ExternalAPIService)] = [
            ("musicbrainz", musicBrainz),
            ("discogs", discogs),
            ("applemusic", appleMusic),
        ]
        let query = SourceQuery(
            artist: artist,
            album: album,
            currentLibraryYear: currentLibraryYear,
            earliestTrackAddedYear: earliestTrackAddedYear,
            timeout: timeout
        )

        let results = await withTaskGroup(
            of: YearResult.self,
            returning: [YearResult].self
        ) { group in
            for (sourceName, service) in sources {
                group.addTask { [log] in
                    await Self.fetchWithTimeout(
                        source: sourceName,
                        service: service,
                        query: query,
                        log: log
                    )
                }
            }

            var collected: [YearResult] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        return Self.aggregateResults(results)
    }

    // MARK: - Private

    /// Fetches a year result from a single source with a timeout race.
    ///
    /// Spawns two child tasks: the actual API call and a sleep timer.
    /// Whichever finishes first wins. If the timer fires first, the API
    /// call is cancelled and an empty result is returned.
    private static func fetchWithTimeout(
        source: String,
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
            log.warning("\(source, privacy: .public) timed out after \(query.timeout, privacy: .public)")
            return YearResult()
        } catch is CancellationError {
            log.debug("\(source, privacy: .public) cancelled")
            return YearResult()
        } catch {
            log.error("\(source, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return YearResult()
        }
    }

    /// Combines year scores from all source results and selects the best year.
    ///
    /// Merges `yearScores` dictionaries additively. The year with the highest
    /// combined score wins. `isDefinitive` is true when 2+ sources agree on
    /// the same year. Final confidence is capped at 100.
    private static func aggregateResults(
        _ results: [YearResult]
    ) -> YearResult {
        var combinedScores: [Int: Int] = [:]

        for result in results {
            for (year, score) in result.yearScores {
                combinedScores[year, default: 0] += score
            }
        }

        guard let (bestYear, bestScore) = combinedScores.max(
            by: { $0.value < $1.value }
        ) else {
            return YearResult()
        }

        let agreeingSourceCount = results.count(where: { $0.year == bestYear })
        let isDefinitive = agreeingSourceCount >= 2

        return YearResult(
            year: bestYear,
            isDefinitive: isDefinitive,
            confidence: min(bestScore, 100),
            yearScores: combinedScores
        )
    }
}

// MARK: - SourceQuery

/// Bundles query parameters for a single source fetch.
private struct SourceQuery: Sendable {
    let artist: String
    let album: String
    let currentLibraryYear: Int?
    let earliestTrackAddedYear: Int?
    let timeout: Duration
}

// MARK: - OrchestratorTimeoutError

/// Internal error used to distinguish timeout from other failures.
private struct OrchestratorTimeoutError: Error {}
