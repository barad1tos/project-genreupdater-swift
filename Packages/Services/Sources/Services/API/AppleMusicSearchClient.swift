// AppleMusicSearchClient.swift — MusicKit catalog search for genre/year data
// Phase 4: API + Cache

import Core
import Foundation
import MusicKit
import OSLog

// MARK: - AppleMusicSearchClient

/// Apple Music catalog search client for album year and genre data.
///
/// Uses MusicKit's `MusicCatalogSearchRequest` for native catalog access.
/// No rate limiting needed — Apple manages request throttling internally.
/// Requires MusicKit entitlement in the app target; returns empty results
/// gracefully when authorization is unavailable (e.g., in unit tests).
///
/// - Note: Artist activity period and start year are not exposed by MusicKit,
///   so those methods always return `nil`.
public struct AppleMusicSearchClient: ExternalAPIService, Sendable {
    public static let defaultITunesHost = "itunes.apple.com"
    public static let defaultITunesScheme = "https"

    private let session: URLSession
    private let countryCode: String
    private let entity: String
    private let limit: Int
    private let iTunesConfiguration: ITunesSearchConfiguration
    private let lookupFallbackEnabled: Bool
    private let log = AppLogger.api

    public init(
        session: URLSession = .shared,
        countryCode: String = "US",
        entity: String = "album",
        limit: Int = 200,
        iTunesConfiguration: ITunesSearchConfiguration = ITunesSearchConfiguration(),
        lookupFallbackEnabled: Bool = true
    ) {
        self.session = session
        self.countryCode = countryCode
        self.entity = entity
        self.limit = min(max(limit, 1), 200)
        self.iTunesConfiguration = iTunesConfiguration
        self.lookupFallbackEnabled = lookupFallbackEnabled
    }

    // MARK: - ExternalAPIService

    /// Search the Apple Music catalog for album year and genre data.
    ///
    /// Performs a `MusicCatalogSearchRequest` combining artist and album name.
    /// Returns a `YearResult` with confidence 70 when a matching album is found,
    /// or an empty result when MusicKit is not authorized or no match exists.
    ///
    /// - Parameters:
    ///   - artist: The artist name to search for.
    ///   - album: The album name to search for.
    ///   - currentLibraryYear: The year currently set in the user's library (unused).
    ///   - earliestTrackAddedYear: The earliest year a track was added (unused).
    /// - Returns: A `YearResult` with the album's release year and confidence.
    public func getAlbumYear(
        artist: String,
        album: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        let authorizationStatus = await requestAuthorization()
        guard authorizationStatus == .authorized else {
            log.info("MusicKit not authorized, skipping Apple Music catalog search")
            return YearResult()
        }

        var request = MusicCatalogSearchRequest(
            term: "\(artist) \(album)",
            types: [Album.self]
        )
        request.limit = 5

        let response: MusicCatalogSearchResponse
        do {
            response = try await request.response()
        } catch {
            log.error("MusicKit catalog search failed: \(error.localizedDescription, privacy: .public)")
            return YearResult()
        }

        guard let bestMatch = response.albums.first else {
            log.debug(
                "No Apple Music results for \(artist, privacy: .private) - \(album, privacy: .private)"
            )
            return YearResult()
        }

        guard let releaseDate = bestMatch.releaseDate else {
            log.debug(
                "Apple Music match has no release date for \(artist, privacy: .private) - \(album, privacy: .private)"
            )
            return YearResult()
        }

        let year = Calendar.current.component(.year, from: releaseDate)
        let genres = bestMatch.genreNames

        log.debug(
            "Apple Music: \(artist, privacy: .private) - \(album, privacy: .private) -> year=\(year, privacy: .public), genres=\(genres.joined(separator: ", "), privacy: .private)"
        )

        return YearResult(
            year: year,
            isDefinitive: false,
            confidence: 70,
            yearScores: [year: 70]
        )
    }

    /// Return iTunes Search API album candidates for parity year scoring.
    public func getReleaseCandidates(
        artist: String,
        album: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> [ReleaseCandidate] {
        guard let searchURL = Self.buildITunesSearchURL(
            term: "\(artist) \(album)",
            countryCode: countryCode,
            entity: entity,
            limit: limit,
            configuration: iTunesConfiguration
        ) else {
            return []
        }

        let searchResults = try await fetchITunesResults(from: searchURL)
        let directCandidates = Self.candidates(
            from: searchResults,
            artist: artist,
            album: album
        )
        if !directCandidates.isEmpty || !lookupFallbackEnabled {
            return directCandidates
        }

        guard let artistID = try await findArtistID(artist: artist) else {
            return []
        }
        let lookupResults = try await lookupArtistAlbums(artistID: artistID)
        return Self.candidates(
            from: lookupResults,
            artist: artist,
            album: album
        )
    }

    /// MusicKit does not expose structured artist activity periods.
    ///
    /// Always returns `(nil, nil)`.
    public func getArtistActivityPeriod(
        normalizedArtist _: String
    ) async throws -> (start: Int?, end: Int?) {
        (nil, nil)
    }

    /// MusicKit does not expose artist career start year.
    ///
    /// Uses the public iTunes Search API as a parity fallback with the Python
    /// implementation, taking the earliest matching album release year.
    public func getArtistStartYear(
        normalizedArtist: String
    ) async throws -> Int? {
        guard let url = Self.buildArtistAlbumsSearchURL(
            artist: normalizedArtist,
            countryCode: countryCode,
            entity: entity,
            limit: limit,
            configuration: iTunesConfiguration
        ) else {
            log.warning("Failed to build iTunes artist albums URL for \(normalizedArtist, privacy: .private)")
            return nil
        }

        let results = try await fetchITunesResults(from: url)
        let artist = normalizeForMatching(normalizedArtist)
        let years = results.compactMap { result in
            Self.releaseYear(from: result, normalizedArtist: artist)
        }

        return years.min()
    }

    /// No initialization required — MusicKit manages its own state.
    public func initialize(force _: Bool) async throws {
        // No-op: MusicKit handles initialization internally
    }

    /// No cleanup required — MusicKit manages its own connections.
    public func close() async {
        // No-op: no persistent connections to close
    }

    // MARK: - Private

    /// Request MusicKit authorization, returning the resulting status.
    ///
    /// In a running app this prompts the user; in test context it returns
    /// the current (typically unauthorized) status without blocking.
    private func requestAuthorization() async -> MusicAuthorization.Status {
        await MusicAuthorization.request()
    }

    static func buildArtistAlbumsSearchURL(
        artist: String,
        countryCode: String,
        entity: String = "album",
        limit: Int = 200,
        configuration: ITunesSearchConfiguration = ITunesSearchConfiguration()
    ) -> URL? {
        let searchEntity = entity.trimmingCharacters(in: .whitespacesAndNewlines)
        let clampedLimit = min(max(limit, 1), 200)
        var components = URLComponents()
        components.scheme = configuration.scheme
        components.host = configuration.host
        components.path = configuration.searchPath
        components.queryItems = [
            URLQueryItem(name: "term", value: artist),
            URLQueryItem(name: "country", value: countryCode),
            URLQueryItem(name: "entity", value: searchEntity.isEmpty ? "album" : searchEntity),
            URLQueryItem(name: "limit", value: String(clampedLimit)),
        ]
        return components.url
    }

    static func buildITunesSearchURL(
        term: String,
        countryCode: String,
        entity: String,
        limit: Int,
        configuration: ITunesSearchConfiguration = ITunesSearchConfiguration()
    ) -> URL? {
        buildArtistAlbumsSearchURL(
            artist: term,
            countryCode: countryCode,
            entity: entity,
            limit: limit,
            configuration: configuration
        )
    }

    private func fetchITunesResults(from url: URL) async throws -> [ITunesAlbumResult] {
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            log.warning("iTunes request returned a non-HTTP response")
            throw ITunesSearchError.nonHTTPResponse
        }

        guard httpResponse.statusCode == 200 else {
            log.warning("iTunes request returned HTTP \(httpResponse.statusCode, privacy: .public)")
            throw ITunesSearchError.unsuccessfulStatusCode(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(
            ITunesArtistAlbumsResponse.self,
            from: data
        ).results
    }

    private func findArtistID(artist: String) async throws -> Int? {
        guard let url = Self.buildITunesSearchURL(
            term: artist,
            countryCode: countryCode,
            entity: "musicArtist",
            limit: 5,
            configuration: iTunesConfiguration
        ) else {
            return nil
        }

        let results = try await fetchITunesResults(from: url)
        let normalizedArtist = normalizeForMatching(artist)
        return results.first {
            normalizeForMatching($0.artistName ?? "") == normalizedArtist
        }?.artistID
    }

    private func lookupArtistAlbums(artistID: Int) async throws -> [ITunesAlbumResult] {
        var components = URLComponents()
        components.scheme = iTunesConfiguration.scheme
        components.host = iTunesConfiguration.host
        components.path = iTunesConfiguration.lookupPath
        components.queryItems = [
            URLQueryItem(name: "id", value: String(artistID)),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components.url else { return [] }
        return try await fetchITunesResults(from: url)
    }

    private static func candidates(
        from results: [ITunesAlbumResult],
        artist: String,
        album: String
    ) -> [ReleaseCandidate] {
        let normalizedArtist = normalizeForMatching(artist)
        let normalizedAlbum = normalizeForMatching(album)

        return results.compactMap { result in
            let resultArtist = normalizeForMatching(result.artistName ?? "")
            let resultAlbum = normalizeForMatching(result.collectionName ?? "")
            guard resultArtist == normalizedArtist,
                  resultAlbum == normalizedAlbum,
                  let year = year(from: result)
            else {
                return nil
            }

            return ReleaseCandidate(
                artist: result.artistName ?? artist,
                album: result.collectionName ?? album,
                year: year,
                source: .itunes,
                releaseType: .album,
                status: .official,
                country: result.country?.lowercased()
            )
        }
    }

    private static func releaseYear(
        from result: ITunesAlbumResult,
        normalizedArtist: String
    ) -> Int? {
        let resultArtist = normalizeForMatching(result.artistName ?? "")
        guard !resultArtist.isEmpty,
              resultArtist.contains(normalizedArtist) || normalizedArtist.contains(resultArtist)
        else {
            return nil
        }

        return year(from: result)
    }

    private static func year(from result: ITunesAlbumResult) -> Int? {
        guard let releaseDate = result.releaseDate?.trimmingCharacters(in: .whitespacesAndNewlines),
              releaseDate.count >= 4 else { return nil }
        let yearPrefix = releaseDate.prefix(4)
        guard yearPrefix.allSatisfy(\.isNumber) else { return nil }
        return Int(yearPrefix)
    }
}

public struct ITunesSearchConfiguration: Sendable {
    public let scheme: String
    public let host: String
    public let searchPath: String
    public let lookupPath: String

    public init(
        scheme: String = AppleMusicSearchClient.defaultITunesScheme,
        host: String = AppleMusicSearchClient.defaultITunesHost,
        searchPath: String = Self.endpointPath("search"),
        lookupPath: String = Self.endpointPath("lookup")
    ) {
        self.scheme = Self.resolved(scheme, fallback: AppleMusicSearchClient.defaultITunesScheme)
        self.host = Self.resolved(host, fallback: AppleMusicSearchClient.defaultITunesHost)
        self.searchPath = Self.resolvedEndpointPath(searchPath, fallback: Self.endpointPath("search"))
        self.lookupPath = Self.resolvedEndpointPath(lookupPath, fallback: Self.endpointPath("lookup"))
    }

    public static func endpointPath(_ endpoint: String) -> String {
        "/" + endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolved(_ value: String, fallback: String) -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? fallback : trimmedValue
    }

    private static func resolvedEndpointPath(_ path: String, fallback: String) -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return fallback }
        if trimmedPath.hasPrefix("/") {
            return trimmedPath
        }
        return "/" + trimmedPath
    }
}

private struct ITunesArtistAlbumsResponse: Decodable {
    let results: [ITunesAlbumResult]
}

private struct ITunesAlbumResult: Decodable {
    let artistName: String?
    let collectionName: String?
    let releaseDate: String?
    let artistID: Int?
    let country: String?

    private enum CodingKeys: String, CodingKey {
        case artistName
        case collectionName
        case releaseDate
        case artistID = "artistId"
        case country
    }
}

private enum ITunesSearchError: LocalizedError {
    case nonHTTPResponse
    case unsuccessfulStatusCode(Int)

    var errorDescription: String? {
        switch self {
        case .nonHTTPResponse:
            "iTunes request returned a non-HTTP response"
        case let .unsuccessfulStatusCode(statusCode):
            "iTunes request returned HTTP \(statusCode)"
        }
    }
}
