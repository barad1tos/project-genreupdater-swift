// MusicBrainzModels.swift — Codable DTOs for MusicBrainz JSON API responses
// Phase 4: API + Cache

import Foundation

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
    let artistCredits: [MBArtistCredit]?

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case primaryType = "primary-type"
        case firstReleaseDate = "first-release-date"
        case tags
        case genres
        case artistCredits = "artist-credit"
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

struct MBArtistCredit: Codable {
    let artist: MBCreditedArtist?
}

struct MBCreditedArtist: Codable {
    let name: String?
    let aliases: [MBArtistAlias]?
}

struct MBArtistAlias: Codable {
    let name: String?
}

// MARK: - Release Search

/// Top-level response from MusicBrainz release search endpoint.
///
/// Maps to: `GET /ws/2/release?release-group=...&fmt=json`.
struct MBReleaseSearchResponse: Codable {
    let releases: [MBRelease]
}

/// A concrete MusicBrainz release inside a release group.
///
/// Release-level fields preserve status and country data that release groups do
/// not expose, while the release group remains the source of original year.
struct MBRelease: Codable {
    let title: String?
    let date: String?
    let country: String?
    let status: String?

    /// Extracts a four-digit year from `date`.
    ///
    /// Handles both "YYYY" and "YYYY-MM-DD" formats.
    var releaseYear: Int? {
        guard let dateString = date,
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
    let area: MBArea?
    let beginArea: MBArea?
    let endArea: MBArea?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case lifeSpan = "life-span"
        case type
        case area
        case beginArea = "begin-area"
        case endArea = "end-area"
    }
}

/// A MusicBrainz area (country/region/city) attached to an artist.
struct MBArea: Codable {
    let name: String?
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
