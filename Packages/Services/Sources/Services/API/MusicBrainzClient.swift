// MusicBrainzClient.swift — JSON API client for MusicBrainz metadata
// Phase 4: API + Cache

import Core
import Foundation
import OSLog

// MARK: - MusicBrainzClient

/// MusicBrainz API client for album year and artist activity data.
///
/// Uses JSON format (`&fmt=json`) instead of default XML.
/// Rate limited at 1 request/second per MusicBrainz policy.
/// Requires a descriptive User-Agent header per API terms of service.
///
/// Endpoints used:
/// - `/ws/2/release-group?query=...` — album year, genres/tags
/// - `/ws/2/artist?query=...` — artist activity period (life-span)
public struct MusicBrainzClient: ExternalAPIService, Sendable {
    private static let baseURL = "https://musicbrainz.org/ws/2"

    private let userAgent: String
    private let session: URLSession
    private let rateLimiter: TokenBucketRateLimiter
    private let log = AppLogger.api

    /// Creates a MusicBrainz API client.
    ///
    /// - Parameters:
    ///   - contactEmail: Contact email included in User-Agent header per MusicBrainz policy.
    ///   - session: URL session for network requests. Defaults to `.shared`.
    ///   - rateLimiter: Rate limiter for throttling. Defaults to 1 req/sec.
    public init(
        appName: String = "GenreUpdater/1.0",
        contactEmail: String = "",
        session: URLSession = .shared,
        rateLimiter: TokenBucketRateLimiter? = nil
    ) {
        let trimmedAppName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveAppName = trimmedAppName.isEmpty ? "GenreUpdater/1.0" : trimmedAppName
        if contactEmail.isEmpty {
            self.userAgent = "\(effectiveAppName) (https://github.com/barad1tos/project-genreupdater-swift)"
        } else {
            self.userAgent = "\(effectiveAppName) (\(contactEmail); https://github.com/barad1tos/project-genreupdater-swift)"
        }
        self.session = session
        self.rateLimiter = rateLimiter ?? TokenBucketRateLimiter(
            maxTokens: 1,
            refillInterval: .seconds(1)
        )
    }

    // MARK: - ExternalAPIService

    public func getAlbumYear(
        artist: String,
        album: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        let releaseGroups = try await searchReleaseGroups(artist: artist, album: album, limit: 5)

        guard let bestMatch = releaseGroups.first,
              let year = bestMatch.releaseYear
        else {
            log.debug("No release group results for \(artist, privacy: .private) - \(album, privacy: .private)")
            return YearResult()
        }

        let confidence = bestMatch.primaryType == "Album" ? 80 : 60

        log.debug(
            "MusicBrainz: \(artist, privacy: .private) - \(album, privacy: .private) -> \(year, privacy: .public) (confidence: \(confidence, privacy: .public))"
        )

        return YearResult(
            year: year,
            isDefinitive: false,
            confidence: confidence,
            yearScores: [year: confidence]
        )
    }

    public func getReleaseCandidates(
        artist: String,
        album: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> [ReleaseCandidate] {
        let releaseGroups = try await searchReleaseGroups(artist: artist, album: album, limit: 10)
        var candidates: [ReleaseCandidate] = []

        for (index, group) in releaseGroups.enumerated() {
            let releases = index < 3 ? try await fetchReleases(for: group.id) : []
            candidates.append(contentsOf: Self.releaseCandidates(
                from: group,
                releases: releases,
                queryArtist: artist
            ))
        }

        return candidates
    }

    public func getArtistActivityPeriod(
        normalizedArtist: String
    ) async throws -> (start: Int?, end: Int?) {
        guard let artist = try await fetchFirstArtist(named: normalizedArtist) else {
            log.debug("No artist results for \(normalizedArtist, privacy: .private)")
            return (nil, nil)
        }

        return (artist.lifeSpan?.beginYear, artist.lifeSpan?.endYear)
    }

    public func getArtistStartYear(
        normalizedArtist: String
    ) async throws -> Int? {
        let (start, _) = try await getArtistActivityPeriod(
            normalizedArtist: normalizedArtist
        )
        return start
    }

    public func initialize(force: Bool) async throws {
        // No initialization needed — stateless HTTP client
    }

    public func close() async {
        // No cleanup needed — URLSession lifecycle managed externally
    }

    // MARK: - URL Builders

    /// Builds a release group search URL for the given artist and album.
    ///
    /// Query format: `artist:"<artist>" AND release:"<album>"` with `&fmt=json`.
    static func buildReleaseGroupSearchURL(
        artist: String,
        album: String,
        limit: Int = 5
    ) -> URL? {
        var components = URLComponents(string: "\(baseURL)/release-group")
        components?.queryItems = [
            URLQueryItem(
                name: "query",
                value: "artist:\"\(artist)\" AND release:\"\(album)\""
            ),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        return components?.url
    }

    static func buildReleaseSearchURL(
        releaseGroupID: String,
        limit: Int = 100
    ) -> URL? {
        var components = URLComponents(string: "\(baseURL)/release")
        components?.queryItems = [
            URLQueryItem(name: "release-group", value: releaseGroupID),
            URLQueryItem(name: "inc", value: "media+artist-credits"),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        return components?.url
    }

    /// Builds an artist search URL for the given artist name.
    ///
    /// Query format: `artist:"<artist>"` with `&fmt=json`.
    static func buildArtistSearchURL(artist: String) -> URL? {
        var components = URLComponents(string: "\(baseURL)/artist")
        components?.queryItems = [
            URLQueryItem(
                name: "query",
                value: "artist:\"\(artist)\""
            ),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        return components?.url
    }

    // MARK: - Request Building

    /// Creates a URLRequest with required MusicBrainz headers.
    ///
    /// Sets `User-Agent` (required by MusicBrainz API policy) and
    /// `Accept: application/json` for JSON responses.
    func makeRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: - Private

    private func searchReleaseGroups(
        artist: String,
        album: String,
        limit: Int
    ) async throws -> [MBReleaseGroup] {
        let releaseGroups = try await fetchReleaseGroups(artist: artist, album: album, limit: limit)
        guard releaseGroups.isEmpty else { return releaseGroups }

        guard Self.shouldRetryWithCanonicalArtist(for: artist),
              let canonicalArtist = try await canonicalArtistName(for: artist)
        else {
            return []
        }

        let normalizedArtist = normalizeForMatching(artist)
        let normalizedCanonicalArtist = normalizeForMatching(canonicalArtist)
        guard !normalizedCanonicalArtist.isEmpty,
              normalizedCanonicalArtist != normalizedArtist
        else {
            return []
        }

        log.debug(
            "MusicBrainz canonical fallback for \(artist, privacy: .private) -> \(normalizedCanonicalArtist, privacy: .private)"
        )
        return try await fetchReleaseGroups(artist: normalizedCanonicalArtist, album: album, limit: limit)
    }

    private func fetchReleaseGroups(
        artist: String,
        album: String,
        limit: Int
    ) async throws -> [MBReleaseGroup] {
        guard let url = Self.buildReleaseGroupSearchURL(
            artist: artist,
            album: album,
            limit: limit
        ) else {
            log.warning("Failed to build release group search URL for \(artist, privacy: .private)")
            return []
        }

        let data = try await fetchWithRateLimit(url: url)
        return try JSONDecoder().decode(
            MBReleaseGroupSearchResponse.self,
            from: data
        ).releaseGroups
    }

    private func fetchReleases(for releaseGroupID: String) async throws -> [MBRelease] {
        guard let url = Self.buildReleaseSearchURL(releaseGroupID: releaseGroupID) else {
            log.warning("Failed to build release search URL for release group \(releaseGroupID, privacy: .public)")
            return []
        }

        let data = try await fetchWithRateLimit(url: url)
        return try JSONDecoder().decode(
            MBReleaseSearchResponse.self,
            from: data
        ).releases
    }

    private func canonicalArtistName(for artist: String) async throws -> String? {
        try await fetchFirstArtist(named: artist)?.name
    }

    private func fetchFirstArtist(named artist: String) async throws -> MBArtist? {
        guard let url = Self.buildArtistSearchURL(artist: artist) else {
            log.warning("Failed to build artist search URL for \(artist, privacy: .private)")
            return nil
        }

        let data = try await fetchWithRateLimit(url: url)
        let response = try JSONDecoder().decode(
            MBArtistSearchResponse.self,
            from: data
        )
        return response.artists.first
    }

    private static func shouldRetryWithCanonicalArtist(for artist: String) -> Bool {
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedArtist.isEmpty else { return false }

        let script = dominantScript(of: trimmedArtist)
        return script != .latin && script != .unknown
    }

    private static func releaseType(from primaryType: String?) -> ReleaseType {
        switch primaryType?.lowercased() {
        case "single": .single
        case "ep": .ep
        case "compilation": .compilation
        case "live": .live
        default: .album
        }
    }

    private static func releaseCandidates(
        from group: MBReleaseGroup,
        releases: [MBRelease],
        queryArtist: String
    ) -> [ReleaseCandidate] {
        var candidates = groupOnlyCandidate(from: group, queryArtist: queryArtist).map { [$0] } ?? []
        let detailedCandidates = releases.compactMap { release -> ReleaseCandidate? in
            guard let year = release.releaseYear else { return nil }
            let candidate = ReleaseCandidate(
                artist: queryArtist,
                album: albumTitle(releaseTitle: release.title, groupTitle: group.title),
                year: year,
                source: .musicBrainz,
                releaseType: releaseType(from: group.primaryType),
                status: releaseStatus(from: release.status),
                country: normalizedCountry(release.country),
                isReissue: false,
                mbReleaseGroupID: group.id,
                mbReleaseGroupFirstYear: group.releaseYear
            )
            return candidates.contains(candidate) ? nil : candidate
        }

        candidates.append(contentsOf: detailedCandidates)
        return candidates
    }

    private static func groupOnlyCandidate(
        from group: MBReleaseGroup,
        queryArtist: String
    ) -> ReleaseCandidate? {
        guard let year = group.releaseYear else { return nil }
        return ReleaseCandidate(
            artist: queryArtist,
            album: group.title,
            year: year,
            source: .musicBrainz,
            releaseType: releaseType(from: group.primaryType),
            status: .official,
            isReissue: false,
            mbReleaseGroupID: group.id,
            mbReleaseGroupFirstYear: year
        )
    }

    private static func albumTitle(releaseTitle: String?, groupTitle: String) -> String {
        guard let title = releaseTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return groupTitle
        }
        return title
    }

    private static func normalizedCountry(_ country: String?) -> String? {
        guard let country = country?.trimmingCharacters(in: .whitespacesAndNewlines),
              !country.isEmpty else {
            return nil
        }
        return country.lowercased()
    }

    private static func releaseStatus(from status: String?) -> ReleaseStatus {
        guard let normalizedStatus = status?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !normalizedStatus.isEmpty else {
            return .official
        }

        if normalizedStatus == "official" {
            return .official
        }
        if normalizedStatus == "bootleg" {
            return .bootleg
        }
        if normalizedStatus == "pseudo-release" {
            return .pseudoRelease
        }
        if normalizedStatus.contains("promotion") || normalizedStatus.contains("promo") {
            return .promotional
        }
        return .other
    }

    /// Acquires a rate limit token, then performs the HTTP request.
    ///
    /// Handles HTTP status codes: 200 (success), 400 (bad request),
    /// 503 (service unavailable), and all other codes as generic HTTP errors.
    private func fetchWithRateLimit(url: URL) async throws -> Data {
        let waitTime = await rateLimiter.acquire()
        if waitTime > .zero {
            log.debug("Rate limited, waited \(waitTime, privacy: .public)")
        }

        let request = makeRequest(for: url)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MusicBrainzError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return data
        case 400:
            throw MusicBrainzError.badRequest
        case 503:
            throw MusicBrainzError.serviceUnavailable
        default:
            throw MusicBrainzError.httpError(httpResponse.statusCode)
        }
    }
}

// MARK: - MusicBrainzError

/// Errors from MusicBrainz API requests.
public enum MusicBrainzError: Error, Sendable, LocalizedError {
    /// Response was not a valid HTTP response.
    case invalidResponse
    /// Server returned 400 Bad Request (malformed query).
    case badRequest
    /// Server returned 503 Service Unavailable (rate limited or down).
    case serviceUnavailable
    /// Server returned an unexpected HTTP status code.
    case httpError(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "MusicBrainz returned an invalid response"
        case .badRequest:
            "MusicBrainz rejected the request as malformed (400)"
        case .serviceUnavailable:
            "MusicBrainz is temporarily unavailable (503)"
        case let .httpError(code):
            "MusicBrainz returned HTTP \(code)"
        }
    }
}
