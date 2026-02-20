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
    private let log = AppLogger.api

    public init() {}

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
    /// Always returns `nil`.
    public func getArtistStartYear(
        normalizedArtist: String
    ) async throws -> Int? {
        nil
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
}
