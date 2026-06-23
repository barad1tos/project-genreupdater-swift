// DiscogsClient.swift — REST API client for Discogs metadata
// Phase 4: API + Cache

import Core
import Foundation
import OSLog

// MARK: - DiscogsClient

/// Discogs REST API client for album year and genre data.
///
/// Authenticates via Personal Access Token stored in the Keychain.
/// Rate limited at 60 requests/minute per Discogs policy.
///
/// Endpoints used:
/// - `/database/search?artist=...&release_title=...&type=master` — find master releases
/// - `/releases/{id}` — release detail fallback when search results omit year
/// - `/masters/{id}` — master release details (year, genres, styles)
///
/// Discogs does not expose structured artist activity periods,
/// so `getArtistActivityPeriod` and `getArtistStartYear` return `nil`.
public struct DiscogsClient: ExternalAPIService, Sendable {
    /// Default public Discogs API endpoint used when no custom base URL is provided.
    public static let defaultBaseURL = APIAuthConfig.defaultDiscogsBaseURL
    /// Keychain service identifier used for Discogs token storage.
    public static let keychainService = "com.genreupdater.discogs"
    /// Keychain account identifier used for Discogs token storage.
    public static let keychainAccount = "personal-access-token"

    private static let releaseDetailLookupLimit = 10

    private let userAgent: String
    private let session: URLSession
    private let rateLimiter: TokenBucketRateLimiter
    private let token: String?
    private let baseURL: URL
    private let log = AppLogger.api

    public var isConfigured: Bool {
        token?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// Creates a Discogs client with an explicit token.
    ///
    /// Use this initializer for testing or when the token is already available.
    ///
    /// - Parameters:
    ///   - token: Personal Access Token for Discogs API authentication.
    ///   - contactEmail: Contact email included in User-Agent header.
    ///   - session: URL session for network requests. Defaults to `.shared`.
    ///   - rateLimiter: Rate limiter for throttling. Defaults to 60 req/min.
    ///   - baseURL: Base Discogs API URL. Defaults to the public Discogs API endpoint.
    public init(
        token: String? = nil,
        contactEmail: String = "",
        session: URLSession = .shared,
        rateLimiter: TokenBucketRateLimiter? = nil,
        baseURL: URL = Self.defaultBaseURL
    ) {
        if contactEmail.isEmpty {
            self.userAgent = "GenreUpdater/1.0"
        } else {
            self.userAgent = "GenreUpdater/1.0 (\(contactEmail))"
        }
        self.token = token
        self.session = session
        self.baseURL = baseURL
        self.rateLimiter = rateLimiter ?? TokenBucketRateLimiter(
            maxTokens: 60,
            refillInterval: .seconds(1)
        )
    }

    /// Creates a Discogs client by loading the token from the Keychain.
    ///
    /// - Parameters:
    ///   - contactEmail: Contact email included in User-Agent header.
    ///   - session: URL session for network requests. Defaults to `.shared`.
    ///   - rateLimiter: Rate limiter for throttling. Defaults to 60 req/min.
    ///   - baseURL: Base Discogs API URL. Defaults to the public Discogs API endpoint.
    /// - Returns: A configured `DiscogsClient`.
    /// - Throws: `KeychainError` if the Keychain read fails.
    public static func fromKeychain(
        contactEmail: String = "",
        session: URLSession = .shared,
        rateLimiter: TokenBucketRateLimiter? = nil,
        baseURL: URL = Self.defaultBaseURL
    ) throws -> Self {
        let token = try retrieveSavedToken(keychain: KeychainHelper())
        return Self(
            token: token,
            contactEmail: contactEmail,
            session: session,
            rateLimiter: rateLimiter,
            baseURL: baseURL
        )
    }

    // MARK: - ExternalAPIService

    public func getAlbumYear(
        artist: String,
        album: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        guard token != nil else {
            throw DiscogsError.noToken
        }

        guard let url = Self.buildSearchURL(
            artist: artist,
            album: album,
            baseURL: baseURL
        ) else {
            log.warning("Failed to build Discogs search URL for \(artist, privacy: .private)")
            return YearResult()
        }

        let data = try await fetchWithRateLimit(url: url)
        let response = try JSONDecoder().decode(
            DiscogsSearchResponse.self,
            from: data
        )

        // Prefer canonical release details for the original release year.
        if let result = response.results.first(where: { $0.masterID != nil }),
           let canonicalID = result.masterID {
            let canonicalResult = try await fetchCanonicalYear(releaseID: canonicalID)
            if canonicalResult.year != nil {
                return canonicalResult
            }
        }

        if let year = try await firstSearchResultYear(from: response.results) {
            return YearResult(
                year: year,
                isDefinitive: false,
                confidence: 60,
                yearScores: [year: 60]
            )
        }

        guard let releaseURL = Self.buildSearchURL(
            artist: artist,
            album: album,
            type: "release",
            baseURL: baseURL
        ) else {
            log.warning("Failed to build Discogs release search URL for \(artist, privacy: .private)")
            return YearResult()
        }

        let releaseData = try await fetchWithRateLimit(url: releaseURL)
        let releaseResponse = try JSONDecoder().decode(
            DiscogsSearchResponse.self,
            from: releaseData
        )

        guard let releaseYear = try await firstSearchResultYear(from: releaseResponse.results) else {
            log.debug("No Discogs results for \(artist, privacy: .private) - \(album, privacy: .private)")
            return YearResult()
        }

        return YearResult(
            year: releaseYear,
            isDefinitive: false,
            confidence: 60,
            yearScores: [releaseYear: 60]
        )
    }

    public func getReleaseCandidates(
        artist: String,
        album: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> [ReleaseCandidate] {
        guard token != nil else {
            throw DiscogsError.noToken
        }

        guard let url = Self.buildSearchURL(
            artist: artist,
            album: album,
            type: nil,
            perPage: 10,
            baseURL: baseURL
        ) else {
            log.warning("Failed to build Discogs candidate search URL for \(artist, privacy: .private)")
            return []
        }

        let data = try await fetchWithRateLimit(url: url)
        let response = try JSONDecoder().decode(
            DiscogsSearchResponse.self,
            from: data
        )

        var candidates: [ReleaseCandidate] = []
        var detailLookupCount = 0
        for result in response.results {
            let outcome = try await releaseCandidate(
                from: result,
                artist: artist,
                album: album,
                attemptedLookupCount: detailLookupCount
            )
            if outcome.didAttemptDetailLookup {
                detailLookupCount += 1
            }
            if let candidate = outcome.candidate {
                candidates.append(candidate)
            }
        }
        return candidates
    }

    public func getArtistActivityPeriod(
        normalizedArtist _: String
    ) async throws -> (start: Int?, end: Int?) {
        // Discogs doesn't expose structured artist activity periods
        (nil, nil)
    }

    public func getArtistStartYear(
        normalizedArtist _: String
    ) async throws -> Int? {
        nil
    }

    public func initialize(force _: Bool) async throws {
        // No initialization needed -- stateless HTTP client
    }

    public func close() async {
        // No cleanup needed -- URLSession lifecycle managed externally
    }

    // MARK: - URL Builders

    /// Builds a search URL for master releases matching the given artist and album.
    ///
    /// Query parameters: `artist`, `release_title`, `type=master`, `per_page=5`.
    static func buildSearchURL(
        artist: String,
        album: String,
        type: String? = "master",
        perPage: Int = 5,
        baseURL: URL = Self.defaultBaseURL
    ) -> URL? {
        let searchURL = baseURL
            .appendingPathComponent("database")
            .appendingPathComponent("search")
        var components = URLComponents(url: searchURL, resolvingAgainstBaseURL: false)
        var queryItems = [
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "release_title", value: album),
            URLQueryItem(name: "per_page", value: String(perPage)),
        ]
        if let type {
            queryItems.append(URLQueryItem(name: "type", value: type))
        }
        components?.queryItems = queryItems
        return components?.url
    }

    /// Builds a URL for fetching a specific master release by ID.
    static func buildMasterURL( // swiftlint:disable:this inclusive_language
        releaseID: Int,
        baseURL: URL = Self.defaultBaseURL
    ) -> URL? {
        baseURL
            .appendingPathComponent("masters")
            .appendingPathComponent(String(releaseID))
    }

    /// Builds a URL for fetching a specific release by ID.
    static func buildReleaseURL(
        releaseID: Int,
        baseURL: URL = Self.defaultBaseURL
    ) -> URL? {
        baseURL
            .appendingPathComponent("releases")
            .appendingPathComponent(String(releaseID))
    }

    // MARK: - Request Building

    /// Creates a URLRequest with Discogs authentication and standard headers.
    ///
    /// Sets `Authorization: Discogs token={PAT}`, `User-Agent`, and `Accept`.
    func makeRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let token {
            request.setValue(
                "Discogs token=\(token)",
                forHTTPHeaderField: "Authorization"
            )
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    // MARK: - Private

    private static func albumTitle(from discogsTitle: String, fallback: String) -> String {
        let title = discogsTitle.components(separatedBy: " - ").last ?? fallback
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? fallback : trimmedTitle
    }

    private static func releaseType(from formats: [String]) -> ReleaseType {
        if formats.contains(where: { $0.localizedCaseInsensitiveContains("single") }) {
            return .single
        }
        if formats.contains(where: { $0.localizedCaseInsensitiveContains("ep") }) {
            return .ep
        }
        if formats.contains(where: { $0.localizedCaseInsensitiveContains("compilation") }) {
            return .compilation
        }
        return .album
    }

    private static func isReissue(formats: [String], title: String) -> Bool {
        containsReissueMarker(in: title)
            || formats.contains { containsReissueMarker(in: $0) }
    }

    private static func containsReissueMarker(in value: String) -> Bool {
        let lowered = value.lowercased()
        return lowered.contains("remaster") || lowered.contains("reissue")
    }

    private static func firstNonEmpty(_ values: [String]?) -> String? {
        values?.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func genre(
        from canonicalRelease: DiscogsMasterRelease?,
        result: DiscogsSearchResult
    ) -> String? {
        firstNonEmpty(canonicalRelease?.genres)
            ?? firstNonEmpty(canonicalRelease?.styles)
            ?? firstNonEmpty(result.genre)
            ?? firstNonEmpty(result.style)
    }

    private static func validYear(_ year: Int?) -> Int? {
        guard let year, year > 0 else { return nil }
        return year
    }

    private static func hasReleaseDetailIdentifier(_ result: DiscogsSearchResult) -> Bool {
        result.type.localizedCaseInsensitiveCompare("release") == .orderedSame && result.id > 0
    }

    private func firstSearchResultYear(from results: [DiscogsSearchResult]) async throws -> Int? {
        var detailLookupCount = 0
        for result in results {
            if let year = Self.validYear(result.releaseYear) {
                return year
            }

            let detail = try await releaseDetailYearIfNeeded(
                for: result,
                attemptedLookupCount: detailLookupCount
            )
            if detail.didAttempt {
                detailLookupCount += 1
            }
            if let year = detail.year {
                return year
            }
        }
        return nil
    }

    private func releaseDetailYearIfNeeded(
        for result: DiscogsSearchResult,
        attemptedLookupCount: Int
    ) async throws -> (year: Int?, didAttempt: Bool) {
        guard Self.validYear(result.releaseYear) == nil,
              attemptedLookupCount < Self.releaseDetailLookupLimit,
              Self.hasReleaseDetailIdentifier(result) else {
            return (nil, false)
        }

        return try await (fetchReleaseDetailYear(releaseID: result.id), true)
    }

    private func releaseCandidate(
        from result: DiscogsSearchResult,
        artist: String,
        album: String,
        attemptedLookupCount: Int
    ) async throws -> (candidate: ReleaseCandidate?, didAttemptDetailLookup: Bool) {
        let canonicalRelease = try await fetchCandidateCanonicalRelease(for: result)
        let canonicalYear = canonicalRelease?.year.flatMap { $0 > 0 ? $0 : nil }
        let searchYear = Self.validYear(result.releaseYear)
        var detail: (year: Int?, didAttempt: Bool) = (nil, false)
        if canonicalYear == nil, searchYear == nil {
            detail = try await releaseDetailYearIfNeeded(
                for: result,
                attemptedLookupCount: attemptedLookupCount
            )
        }
        guard let year = canonicalYear ?? searchYear ?? detail.year else {
            return (nil, detail.didAttempt)
        }

        let formats = result.format ?? []
        let isUsingCanonicalYear = canonicalYear != nil
        let albumTitle = Self.albumTitle(
            from: isUsingCanonicalYear ? canonicalRelease?.title ?? result.title : result.title,
            fallback: album
        )
        let candidate = ReleaseCandidate(
            artist: artist,
            album: albumTitle,
            year: year,
            source: .discogs,
            releaseType: Self.releaseType(from: formats),
            status: .official,
            country: result.country?.lowercased(),
            isReissue: Self.isReissue(
                formats: isUsingCanonicalYear ? [] : formats,
                title: albumTitle
            ),
            genre: Self.genre(from: canonicalRelease, result: result)
        )
        return (candidate, detail.didAttempt)
    }

    private func fetchReleaseDetailYear(releaseID: Int) async throws -> Int? {
        guard let url = Self.buildReleaseURL(
            releaseID: releaseID,
            baseURL: baseURL
        ) else {
            return nil
        }

        do {
            let data = try await fetchWithRateLimit(url: url)
            let releaseDetail = try JSONDecoder().decode(
                DiscogsReleaseDetail.self,
                from: data
            )
            return Self.validYear(releaseDetail.releaseYear)
        } catch let error as DiscogsError {
            switch error {
            case .httpError:
                log.debug(
                    "Discogs release detail \(releaseID, privacy: .public) unavailable: \(error.localizedDescription, privacy: .public)"
                )
                return nil
            case .noToken, .invalidResponse, .unauthorized, .rateLimited:
                throw error
            }
        } catch let error as DecodingError {
            log.debug(
                "Discogs release detail \(releaseID, privacy: .public) decoding failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        } catch let error as URLError {
            log.debug(
                "Discogs release detail \(releaseID, privacy: .public) transport failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private func fetchCandidateCanonicalRelease(
        for result: DiscogsSearchResult
    ) async throws -> DiscogsMasterRelease? {
        guard let canonicalID = result.masterID else { return nil }
        do {
            return try await fetchCanonicalRelease(releaseID: canonicalID)
        } catch let error as DiscogsError {
            switch error {
            case .httpError:
                log.debug(
                    "Discogs canonical release \(canonicalID, privacy: .public) unavailable: \(error.localizedDescription, privacy: .public)"
                )
                return nil
            case .noToken, .invalidResponse, .unauthorized, .rateLimited:
                throw error
            }
        } catch let error as DecodingError {
            log.debug(
                "Discogs canonical release \(canonicalID, privacy: .public) decoding failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        } catch let error as URLError {
            log.debug(
                "Discogs canonical release \(canonicalID, privacy: .public) transport failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private func fetchCanonicalYear(releaseID: Int) async throws -> YearResult {
        let canonicalRelease: DiscogsMasterRelease?
        do {
            canonicalRelease = try await fetchCanonicalRelease(releaseID: releaseID)
        } catch let error as DiscogsError {
            switch error {
            case .httpError:
                log.debug(
                    "Discogs canonical release \(releaseID, privacy: .public) unavailable for year lookup: \(error.localizedDescription, privacy: .public)"
                )
                return YearResult()
            case .noToken, .invalidResponse, .unauthorized, .rateLimited:
                throw error
            }
        } catch let error as DecodingError {
            log.debug(
                "Discogs canonical release \(releaseID, privacy: .public) year lookup decoding failed: \(error.localizedDescription, privacy: .public)"
            )
            return YearResult()
        } catch let error as URLError {
            log.debug(
                "Discogs canonical release \(releaseID, privacy: .public) year lookup transport failed: \(error.localizedDescription, privacy: .public)"
            )
            return YearResult()
        }

        guard let canonicalRelease,
              let year = canonicalRelease.year,
              year > 0 else {
            return YearResult()
        }

        log.debug(
            "Discogs release \(releaseID, privacy: .public) -> year \(year, privacy: .public)"
        )

        return YearResult(
            year: year,
            isDefinitive: false,
            confidence: 75,
            yearScores: [year: 75]
        )
    }

    private func fetchCanonicalRelease(releaseID: Int) async throws -> DiscogsMasterRelease? {
        guard let url = Self.buildMasterURL(
            releaseID: releaseID,
            baseURL: baseURL
        ) else {
            return nil
        }

        let data = try await fetchWithRateLimit(url: url)
        return try JSONDecoder().decode(
            DiscogsMasterRelease.self,
            from: data
        )
    }

    /// Acquires a rate limit token, then performs the HTTP request.
    ///
    /// Handles HTTP status codes: 200 (success), 401 (unauthorized),
    /// 429 (rate limited), and all other codes as generic HTTP errors.
    private func fetchWithRateLimit(url: URL) async throws -> Data {
        let waitTime = await rateLimiter.acquire()
        if waitTime > .zero {
            log.debug("Discogs rate limited, waited \(waitTime, privacy: .public)")
        }

        let request = makeRequest(for: url)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DiscogsError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return data
        case 401:
            throw DiscogsError.unauthorized
        case 429:
            throw DiscogsError.rateLimited
        default:
            throw DiscogsError.httpError(httpResponse.statusCode)
        }
    }
}

// MARK: - DiscogsError

/// Errors from Discogs API requests.
public enum DiscogsError: Error, Sendable, LocalizedError {
    /// No Personal Access Token configured (not in Keychain or not provided).
    case noToken
    /// Response was not a valid HTTP response.
    case invalidResponse
    /// Server returned 401 Unauthorized (invalid or expired token).
    case unauthorized
    /// Server returned 429 Too Many Requests (rate limit exceeded).
    case rateLimited
    /// Server returned an unexpected HTTP status code.
    case httpError(Int)

    public var errorDescription: String? {
        switch self {
        case .noToken:
            "Discogs Personal Access Token not configured"
        case .invalidResponse:
            "Discogs returned an invalid response"
        case .unauthorized:
            "Discogs authentication failed (401)"
        case .rateLimited:
            "Discogs rate limit exceeded (429)"
        case let .httpError(code):
            "Discogs returned HTTP \(code)"
        }
    }
}
