// DiscogsClient.swift — REST API client for Discogs metadata
import Core
import Foundation
import OSLog

func normalizedReissueKeywords(_ keywords: [String]) -> [String] {
    let normalized = keywords.compactMap { keyword -> String? in
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
    return Set(normalized).sorted()
}

// MARK: - DiscogsClient

/// Discogs REST API client for album year and genre data.
///
/// Authenticates via Personal Access Token stored in the Keychain.
/// Rate limited at 60 requests/minute per Discogs policy.
///
/// Endpoints used:
/// - `/database/search` — fielded, generic, and album-only release searches
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

    private let userAgent: String
    private let session: URLSession
    private let rateLimiter: TokenBucketRateLimiter
    private let token: String?
    private var rawRequestCache: RawAPIRequestCache?
    private var reissueKeywords: [String]
    private var searchConfiguration: DiscogsSearchConfig
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
    ///   - rawRequestCache: Optional cache for raw API responses.
    ///   - reissueKeywords: Release text treated as reissue evidence.
    ///   - searchConfiguration: Search-result and missing-year release-detail limits.
    public init(
        token: String? = nil,
        contactEmail: String = "",
        session: URLSession = .shared,
        rateLimiter: TokenBucketRateLimiter? = nil,
        baseURL: URL = Self.defaultBaseURL,
        rawRequestCache: RawAPIRequestCache? = nil,
        reissueKeywords: [String] = MetadataRuleDefaults.releaseReissues,
        searchConfiguration: DiscogsSearchConfig = DiscogsSearchConfig()
    ) {
        if contactEmail.isEmpty {
            self.userAgent = "GenreUpdater/1.0"
        } else {
            self.userAgent = "GenreUpdater/1.0 (\(contactEmail))"
        }
        self.token = token
        self.rawRequestCache = rawRequestCache
        self.reissueKeywords = normalizedReissueKeywords(reissueKeywords)
        self.searchConfiguration = searchConfiguration
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

        guard let response = try await searchResponse(artist: artist, album: album) else { return YearResult() }
        let canonical = try await canonicalYearOutcome(from: response.results)
        if let result = canonical.result {
            return result
        }

        if let year = try await firstSearchResultYear(
            from: response.results,
            allowsReleaseDetailLookup: false
        ) {
            return Self.yearResult(year)
        }

        let releaseResponse: DiscogsSearchResponse?
        do {
            releaseResponse = try await searchResponse(artist: artist, album: album, type: "release")
        } catch {
            try Self.rethrowTerminal(error)
            throw canonical.failure ?? error
        }
        guard let releaseResponse else {
            if let failure = canonical.failure {
                throw failure
            }
            return YearResult()
        }

        let releaseYear: Int?
        do {
            releaseYear = try await firstSearchResultYear(from: releaseResponse.results)
        } catch {
            try Self.rethrowTerminal(error)
            throw canonical.failure ?? error
        }
        guard let releaseYear else {
            if let failure = canonical.failure {
                throw failure
            }
            log.debug("No Discogs results for \(artist, privacy: .private) - \(album, privacy: .private)")
            return YearResult()
        }

        return Self.yearResult(releaseYear)
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

        guard let response = try await candidateSearchResponse(artist: artist, album: album) else { return [] }

        var candidates: [ReleaseCandidate] = []
        var detailLookupCount = 0
        var firstFailure: (any Error)?
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
            firstFailure = firstFailure ?? outcome.failure
            if let candidate = outcome.candidate,
               Self.matchesArtist(result.title, expected: artist) {
                candidates.append(candidate)
            }
        }
        if candidates.isEmpty, let firstFailure {
            throw firstFailure
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

    private static func matchesArtist(_ title: String, expected artist: String) -> Bool {
        let expectedArtist = normalizedDiscogsArtist(artist)
        let expectedWithoutThe = removingThePrefix(expectedArtist)

        if let separator = title.range(of: " - ") {
            let titleArtist = normalizedDiscogsArtist(String(title[..<separator.lowerBound]))
            if titleArtist == expectedArtist || removingThePrefix(titleArtist) == expectedWithoutThe {
                return true
            }
        }

        let normalizedTitle = normalizedDiscogsArtist(title)
        return normalizedTitle.contains(expectedArtist) || normalizedTitle.contains(expectedWithoutThe)
    }

    private static func normalizedDiscogsArtist(_ artist: String) -> String {
        var normalized = normalizeForMatching(artist)
        if normalized.hasSuffix(", the") {
            normalized = "the \(normalized.dropLast(5))"
        }
        return normalized.replacingOccurrences(
            of: "\\s*\\(\\d+\\)\\s*$",
            with: "",
            options: .regularExpression
        )
    }

    private static func removingThePrefix(_ artist: String) -> String {
        artist.hasPrefix("the ") ? String(artist.dropFirst(4)) : artist
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

    private func isReissue(formats: [String], title: String) -> Bool {
        containsReissueMarker(in: title)
            || formats.contains { containsReissueMarker(in: $0) }
    }

    private func containsReissueMarker(in value: String) -> Bool {
        let lowered = value.lowercased()
        return reissueKeywords.contains { lowered.contains($0) }
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

    private static func yearResult(_ year: Int) -> YearResult {
        YearResult(
            year: year,
            isDefinitive: false,
            confidence: 60,
            yearScores: [year: 60]
        )
    }

    private static func rethrowTerminal(_ error: any Error) throws {
        if error is CancellationError {
            throw error
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            throw urlError
        }
        if Task.isCancelled {
            throw CancellationError()
        }
        guard let discogsError = error as? DiscogsError else { return }
        switch discogsError {
        case .noToken, .unauthorized, .rateLimited:
            throw discogsError
        case .invalidResponse, .httpError:
            return
        }
    }

    private static func hasReleaseDetailIdentifier(_ result: DiscogsSearchResult) -> Bool {
        result.type.localizedCaseInsensitiveCompare("release") == .orderedSame && result.id > 0
    }

    private func searchResponse(
        artist: String,
        album: String,
        type: String? = "master"
    ) async throws -> DiscogsSearchResponse? {
        guard let url = Self.buildSearchURL(
            artist: artist,
            album: album,
            type: type,
            perPage: searchConfiguration.clampedResultLimit,
            baseURL: baseURL
        ) else {
            log.warning("Failed to build Discogs search URL for \(artist, privacy: .private)")
            return nil
        }
        let data = try await fetchWithRateLimit(url: url)
        return try JSONDecoder().decode(DiscogsSearchResponse.self, from: data)
    }

    private func canonicalYearOutcome(
        from results: [DiscogsSearchResult]
    ) async throws -> (result: YearResult?, failure: (any Error)?) {
        guard let canonicalID = results.first(where: { $0.masterID != nil })?.masterID else {
            return (nil, nil)
        }
        do {
            let result = try await fetchCanonicalYear(releaseID: canonicalID)
            return (result.year == nil ? nil : result, nil)
        } catch {
            try Self.rethrowTerminal(error)
            log.debug("Discogs canonical year recovery failed: \(error.localizedDescription, privacy: .public)")
            return (nil, error)
        }
    }

    private func firstSearchResultYear(
        from results: [DiscogsSearchResult],
        allowsReleaseDetailLookup: Bool = true
    ) async throws -> Int? {
        var detailLookupCount = 0
        var firstFailure: (any Error)?
        for result in results {
            if let year = Self.validYear(result.releaseYear) {
                return year
            }

            guard allowsReleaseDetailLookup else {
                continue
            }

            do {
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
            } catch {
                try Self.rethrowTerminal(error)
                detailLookupCount += 1
                firstFailure = firstFailure ?? error
            }
        }
        if let firstFailure {
            throw firstFailure
        }
        return nil
    }

    private func releaseDetailYearIfNeeded(
        for result: DiscogsSearchResult,
        attemptedLookupCount: Int
    ) async throws -> (year: Int?, didAttempt: Bool) {
        guard Self.validYear(result.releaseYear) == nil,
              attemptedLookupCount < searchConfiguration.clampedDetailLookupLimit,
              Self.hasReleaseDetailIdentifier(result) else {
            return (nil, false)
        }

        return try await (fetchReleaseDetailYear(releaseID: result.id), true)
    }

    private func candidateSearchResponse(
        artist: String,
        album: String
    ) async throws -> DiscogsSearchResponse? {
        var firstFailure: (any Error)?
        for search in DiscogsSearch.allCases {
            try Task.checkCancellation()
            guard let url = Self.buildCandidateSearchURL(
                artist: artist,
                album: album,
                search: search,
                perPage: searchConfiguration.clampedResultLimit,
                baseURL: baseURL
            ) else {
                continue
            }

            do {
                let data = try await fetchWithRateLimit(url: url)
                let response = try JSONDecoder().decode(DiscogsSearchResponse.self, from: data)
                try await checkSearchCancellation()
                if !response.results.isEmpty {
                    return response
                }
            } catch {
                try Self.rethrowTerminal(error)
                firstFailure = firstFailure ?? error
            }
        }

        if let firstFailure {
            throw firstFailure
        }
        return nil
    }

    private func checkSearchCancellation() async throws {
        try Task.checkCancellation()
    }

    private func releaseCandidate(
        from result: DiscogsSearchResult,
        artist: String,
        album: String,
        attemptedLookupCount: Int
    ) async throws -> (candidate: ReleaseCandidate?, didAttemptDetailLookup: Bool, failure: (any Error)?) {
        var canonicalRelease: DiscogsMasterRelease?
        var firstFailure: (any Error)?
        do {
            canonicalRelease = try await fetchCandidateCanonicalRelease(for: result)
        } catch {
            try Self.rethrowTerminal(error)
            firstFailure = error
            log.debug(
                "Discogs canonical candidate recovery failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        let canonicalYear = canonicalRelease?.year.flatMap { $0 > 0 ? $0 : nil }
        let searchYear = Self.validYear(result.releaseYear)
        var detail: (year: Int?, didAttempt: Bool) = (nil, false)
        if canonicalYear == nil, searchYear == nil {
            do {
                detail = try await releaseDetailYearIfNeeded(
                    for: result,
                    attemptedLookupCount: attemptedLookupCount
                )
            } catch {
                try Self.rethrowTerminal(error)
                detail.didAttempt = true
                firstFailure = firstFailure ?? error
                log.debug(
                    "Discogs release-detail candidate recovery failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        guard let year = canonicalYear ?? searchYear ?? detail.year else {
            return (nil, detail.didAttempt, firstFailure)
        }

        let formats = result.format ?? []
        let isUsingCanonicalYear = canonicalYear != nil
        let albumTitle = Self.albumTitle(
            from: isUsingCanonicalYear ? canonicalRelease?.title ?? result.title : result.title,
            fallback: album
        )
        let reissueTitle = Self.albumTitle(from: result.title, fallback: album)
        let candidate = ReleaseCandidate(
            artist: artist,
            album: albumTitle,
            year: year,
            source: .discogs,
            releaseType: Self.releaseType(from: formats),
            status: .official,
            country: result.country?.lowercased(),
            isReissue: isReissue(
                formats: formats,
                title: reissueTitle
            ),
            genre: Self.genre(from: canonicalRelease, result: result)
        )
        return (candidate, detail.didAttempt, nil)
    }

    private func fetchReleaseDetailYear(releaseID: Int) async throws -> Int? {
        guard let url = Self.buildReleaseURL(
            releaseID: releaseID,
            baseURL: baseURL
        ) else {
            return nil
        }

        let data = try await fetchWithRateLimit(url: url)
        let releaseDetail = try JSONDecoder().decode(
            DiscogsReleaseDetail.self,
            from: data
        )
        return Self.validYear(releaseDetail.releaseYear)
    }

    private func fetchCandidateCanonicalRelease(
        for result: DiscogsSearchResult
    ) async throws -> DiscogsMasterRelease? {
        guard let canonicalID = result.masterID else { return nil }
        return try await fetchCanonicalRelease(releaseID: canonicalID)
    }

    private func fetchCanonicalYear(releaseID: Int) async throws -> YearResult {
        let canonicalRelease = try await fetchCanonicalRelease(releaseID: releaseID)

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
    /// The Discogs client is built through credential factories that
    /// predate the raw cache; the composition root attaches it here so
    /// every source shares one pre-limiter cache.
    public func withRawRequestCache(_ cache: RawAPIRequestCache?) -> Self {
        var copy = self
        copy.rawRequestCache = cache
        return copy
    }

    /// Returns a copy using the supplied release text as reissue evidence.
    public func withReissueKeywords(_ keywords: [String]) -> Self {
        var copy = self
        copy.reissueKeywords = normalizedReissueKeywords(keywords)
        return copy
    }

    /// Returns a copy using the supplied search-result and missing-year release-detail limits.
    public func withSearchConfiguration(_ configuration: DiscogsSearchConfig) -> Self {
        var copy = self
        copy.searchConfiguration = configuration
        return copy
    }

    private func fetchWithRateLimit(url: URL) async throws -> Data {
        let data: Data = if let rawRequestCache {
            try await rawRequestCache.data(api: "discogs", url: url) {
                try await performRateLimitedFetch(url: url)
            }
        } else {
            try await performRateLimitedFetch(url: url)
        }
        try Task.checkCancellation()
        return data
    }

    private func performRateLimitedFetch(url: URL) async throws -> Data {
        let waitTime = try await rateLimiter.acquireCancellable()
        if waitTime > .zero {
            log.debug("Discogs rate limited, waited \(waitTime, privacy: .public)")
        }

        let request = makeRequest(for: url)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()

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
