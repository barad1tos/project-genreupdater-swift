import Core
import Foundation

extension DiscogsClient {
    /// Builds a search URL for canonical releases matching the given artist and album.
    ///
    /// By default, sends `artist`, `release_title`, `type=master`, and `per_page` set to the
    /// `DiscogsSearchConfig` default result limit. Callers can override `type` and `perPage`.
    static func buildSearchURL(
        artist: String,
        album: String,
        type: String? = "master",
        perPage: Int = DiscogsSearchConfig().clampedResultLimit,
        baseURL: URL = Self.defaultBaseURL
    ) -> URL? {
        let searchURL = baseURL.appendingPathComponent("database").appendingPathComponent("search")
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

    static func buildCandidateSearchURL(
        artist: String,
        album: String,
        search: DiscogsSearch,
        perPage: Int,
        baseURL: URL
    ) -> URL? {
        let searchURL = baseURL
            .appendingPathComponent("database")
            .appendingPathComponent("search")
        var components = URLComponents(url: searchURL, resolvingAgainstBaseURL: false)
        var queryItems: [URLQueryItem] = switch search {
        case .fielded:
            [
                URLQueryItem(name: "artist", value: artist),
                URLQueryItem(name: "release_title", value: album),
            ]
        case .generic:
            [URLQueryItem(name: "q", value: "\(artist) \(album)")]
        case .albumOnly:
            [URLQueryItem(name: "release_title", value: album)]
        }
        queryItems.append(URLQueryItem(name: "type", value: "release"))
        queryItems.append(URLQueryItem(name: "per_page", value: String(perPage)))
        components?.queryItems = queryItems
        return components?.url
    }

    /// Builds a URL for fetching a specific canonical release by ID.
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
}

enum DiscogsSearch: CaseIterable {
    case fielded
    case generic
    case albumOnly
}
