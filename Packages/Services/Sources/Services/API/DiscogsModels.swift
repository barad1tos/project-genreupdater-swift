// DiscogsModels.swift — Codable DTOs for Discogs REST API responses
// Phase 4: API + Cache

import Foundation

// MARK: - Search Response

/// Top-level response from `/database/search`.
///
/// Maps to: `GET /database/search?q=...&type=release`
struct DiscogsSearchResponse: Codable {
    let results: [DiscogsSearchResult]
    let pagination: DiscogsPagination?
}

/// A single result from the Discogs search endpoint.
///
/// Note: `year` arrives as a String from the search API (e.g., "1994"),
/// unlike master release endpoints which return an Int. Use `releaseYear`
/// for the parsed integer value.
struct DiscogsSearchResult: Codable {
    let id: Int
    let title: String
    let year: String?
    let type: String
    // swiftlint:disable:next inclusive_language
    let masterID: Int?
    // swiftlint:disable:next inclusive_language
    let masterURL: String?
    let genre: [String]?
    let style: [String]?

    private enum CodingKeys: String, CodingKey {
        case id, title, year, type, genre, style
        case masterID = "master_id" // swiftlint:disable:this inclusive_language
        case masterURL = "master_url" // swiftlint:disable:this inclusive_language
    }

    /// Parses the string `year` field into an integer.
    ///
    /// Returns `nil` if the year is absent or not a valid integer.
    var releaseYear: Int? {
        guard let year else { return nil }
        return Int(year)
    }
}

/// Pagination metadata from the Discogs API.
///
/// Included in paginated responses to indicate the current page,
/// total page count, items per page, and total item count.
struct DiscogsPagination: Codable {
    let page: Int
    let pages: Int
    let perPage: Int
    let items: Int

    private enum CodingKeys: String, CodingKey {
        case page, pages, items
        case perPage = "per_page"
    }
}

// MARK: - Master Release

/// A Discogs master release, fetched from `/masters/{id}`.
///
/// The master release represents the canonical version of a recording,
/// aggregating all pressings and editions. Contains genre/style arrays
/// and the definitive release year as an Int (unlike search results).
struct DiscogsMasterRelease: Codable { // swiftlint:disable:this inclusive_language
    let id: Int
    let title: String
    let year: Int?
    let genres: [String]?
    let styles: [String]?
    let artists: [DiscogsArtistRef]?
}

/// A reference to an artist within a release or master release.
///
/// Lightweight representation containing only the artist ID and name,
/// without the full profile or membership data.
struct DiscogsArtistRef: Codable {
    let id: Int
    let name: String
}
