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
    private static let itunesBaseURL = "https://itunes.apple.com"

    private let session: URLSession
    private let countryCode: String
    private let entity: String
    private let limit: Int
    private let log = AppLogger.api

    public init(
        session: URLSession = .shared,
        countryCode: String = "US",
        entity: String = "album",
        limit: Int = 200,
        lookupFallbackEnabled: Bool = true
    ) {
        self.session = session
        self.countryCode = countryCode
        self.entity = entity
        self.limit = min(max(limit, 1), 200)
        _ = lookupFallbackEnabled
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

    /// MusicKit does not expose structured artist activity periods.
    ///
    /// Always returns `(nil, nil)`.
    public func getArtistActivityPeriod(
        normalizedArtist: String
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
            limit: limit
        ) else {
            log.warning("Failed to build iTunes artist albums URL for \(normalizedArtist, privacy: .private)")
            return nil
        }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            log.warning("iTunes artist albums search returned a non-HTTP response")
            return nil
        }

        guard httpResponse.statusCode == 200 else {
            log.warning("iTunes artist albums search returned HTTP \(httpResponse.statusCode, privacy: .public)")
            return nil
        }

        let decoded = try JSONDecoder().decode(
            ITunesArtistAlbumsResponse.self,
            from: data
        )
        let artist = normalizeForMatching(normalizedArtist)
        let years = decoded.results.compactMap { result in
            Self.releaseYear(from: result, normalizedArtist: artist)
        }

        return years.min()
    }

    /// No initialization required — MusicKit manages its own state.
    public func initialize(force: Bool) async throws {
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
        limit: Int = 200
    ) -> URL? {
        let searchEntity = entity.trimmingCharacters(in: .whitespacesAndNewlines)
        let clampedLimit = min(max(limit, 1), 200)
        var components = URLComponents(string: "\(itunesBaseURL)/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: artist),
            URLQueryItem(name: "country", value: countryCode),
            URLQueryItem(name: "entity", value: searchEntity.isEmpty ? "album" : searchEntity),
            URLQueryItem(name: "limit", value: String(clampedLimit)),
        ]
        return components?.url
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

        guard let releaseDate = result.releaseDate?.trimmingCharacters(in: .whitespacesAndNewlines),
              releaseDate.count >= 4
        else {
            return nil
        }

        let yearPrefix = releaseDate.prefix(4)
        guard yearPrefix.allSatisfy(\.isNumber) else { return nil }
        return Int(yearPrefix)
    }
}

private struct ITunesArtistAlbumsResponse: Decodable {
    let results: [ITunesAlbumResult]
}

private struct ITunesAlbumResult: Decodable {
    let artistName: String?
    let releaseDate: String?
}
