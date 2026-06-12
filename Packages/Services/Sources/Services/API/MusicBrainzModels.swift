// MusicBrainzModels.swift — Codable DTOs for MusicBrainz JSON API responses
// Phase 4: API + Cache

import Foundation

// MARK: - Release Group Search

/// Top-level response from MusicBrainz release-group search endpoint.
///
/// Maps to: `GET /ws/2/release-group?query=...&fmt=json`
struct MBReleaseGroupSearchResponse: Codable {
    let releaseGroups: [MBReleaseGroup]

    private enum CodingKeys: String, CodingKey {
        case releaseGroups = "release-groups"
    }
}

/// A MusicBrainz release group (album, single, EP, etc.).
///
/// Contains the primary type, first release date, and associated tags/genres
/// used for genre determination and year extraction.
struct MBReleaseGroup: Codable {
    let id: String
    let title: String
    let primaryType: String?
    let firstReleaseDate: String?
    let tags: [MBTag]?
    let genres: [MBGenre]?

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case primaryType = "primary-type"
        case firstReleaseDate = "first-release-date"
        case tags
        case genres
    }

    /// Extracts a four-digit year from `firstReleaseDate`.
    ///
    /// Handles both "YYYY" and "YYYY-MM-DD" formats by taking
    /// the first four characters and converting to Int.
    var releaseYear: Int? {
        guard let dateString = firstReleaseDate,
              dateString.count >= 4 else {
            return nil
        }
        return Int(dateString.prefix(4))
    }
}

/// A community-submitted tag on a MusicBrainz entity.
struct MBTag: Codable {
    let name: String
    let count: Int
}

/// A curated genre classification on a MusicBrainz entity.
struct MBGenre: Codable {
    let name: String
    let count: Int
}

// MARK: - Artist Search

/// Top-level response from MusicBrainz artist search endpoint.
///
/// Maps to: `GET /ws/2/artist?query=...&fmt=json`
struct MBArtistSearchResponse: Codable {
    let artists: [MBArtist]
}

/// A MusicBrainz artist entity.
///
/// Contains identifying information and life-span data used
/// for artist matching and disambiguation.
struct MBArtist: Codable {
    let id: String
    let name: String
    let lifeSpan: MBLifeSpan?
    let type: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case lifeSpan = "life-span"
        case type
    }
}

/// The active period of a MusicBrainz artist.
///
/// Dates may be full ("YYYY-MM-DD"), partial ("YYYY"), or nil.
struct MBLifeSpan: Codable {
    let begin: String?
    let end: String?
    let ended: Bool?

    /// Extracts a four-digit year from the `begin` date string.
    var beginYear: Int? {
        guard let dateString = begin,
              dateString.count >= 4 else {
            return nil
        }
        return Int(dateString.prefix(4))
    }

    /// Extracts a four-digit year from the `end` date string.
    var endYear: Int? {
        guard let dateString = end,
              dateString.count >= 4 else {
            return nil
        }
        return Int(dateString.prefix(4))
    }
}
