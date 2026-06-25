// YearRetrievalConfiguration.swift — release year lookup and scoring configuration.

import Foundation

// MARK: - Year Retrieval Configuration

public struct YearRetrievalConfig: Sendable, Codable {
    public var enabled: Bool = true
    public var preferredAPI: PreferredAPI = .musicbrainz

    public var apiAuth = APIAuthConfig()
    public var rateLimits = APIRateLimits()
    public var logic = YearLogicConfig()
    public var reissueDetection = ReissueDetectionConfig()
    public var scoring = ScoringConfig()
    public var fallback = FallbackConfig()
    public var itunesSearch = ITunesSearchConfig()

    /// API priority per script type (e.g., "latin" -> prefer musicbrainz).
    public var scriptAPIPriorities: [String: ScriptAPIPriority] = [:]

    private enum CodingKeys: String, CodingKey {
        case enabled, preferredAPI, apiAuth, rateLimits, logic, reissueDetection, scoring, fallback
        case itunesSearch, scriptAPIPriorities
    }

    private enum DecodingKeys: String, CodingKey {
        case enabled, preferredAPI, apiAuth, rateLimits, logic, reissueDetection, scoring, fallback
        case itunesSearch, scriptAPIPriorities
        case preferredApi
        case scriptApiPriorities
        case legacyPreferredAPI = "preferred_api"
        case legacyScriptAPIPriorities = "script_api_priorities"
    }

    public init() {
        // Defaults are set on stored properties; custom decoding below preserves those defaults for omitted keys.
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DecodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        preferredAPI = try container.decodeIfPresent(PreferredAPI.self, forKey: .preferredAPI)
            ?? container.decodeIfPresent(PreferredAPI.self, forKey: .preferredApi)
            ?? container.decodeIfPresent(PreferredAPI.self, forKey: .legacyPreferredAPI)
            ?? .musicbrainz
        apiAuth = try container.decodeIfPresent(APIAuthConfig.self, forKey: .apiAuth) ?? APIAuthConfig()
        rateLimits = try container.decodeIfPresent(APIRateLimits.self, forKey: .rateLimits) ?? APIRateLimits()
        logic = try container.decodeIfPresent(YearLogicConfig.self, forKey: .logic) ?? YearLogicConfig()
        reissueDetection = try container
            .decodeIfPresent(ReissueDetectionConfig.self, forKey: .reissueDetection) ?? ReissueDetectionConfig()
        scoring = try container.decodeIfPresent(ScoringConfig.self, forKey: .scoring) ?? ScoringConfig()
        fallback = try container.decodeIfPresent(FallbackConfig.self, forKey: .fallback) ?? FallbackConfig()
        itunesSearch = try container.decodeIfPresent(ITunesSearchConfig.self, forKey: .itunesSearch)
            ?? ITunesSearchConfig()
        scriptAPIPriorities = try container.decodeIfPresent(
            [String: ScriptAPIPriority].self,
            forKey: .scriptAPIPriorities
        ) ?? container.decodeIfPresent(
            [String: ScriptAPIPriority].self,
            forKey: .scriptApiPriorities
        ) ?? container.decodeIfPresent(
            [String: ScriptAPIPriority].self,
            forKey: .legacyScriptAPIPriorities
        ) ?? [:]
    }
}

public enum PreferredAPI: String, Sendable, Codable, CaseIterable {
    case musicbrainz
    case discogs
    case itunes
}

public struct APIRateLimits: Sendable, Codable {
    public var discogsRequestsPerMinute: Int = 55
    public var musicbrainzRequestsPerSecond: Double = 1.0
    public var concurrentAPICalls: Int = 2

    private enum CodingKeys: String, CodingKey {
        case discogsRequestsPerMinute, musicbrainzRequestsPerSecond, concurrentAPICalls
    }

    private enum DecodingKeys: String, CodingKey {
        case discogsRequestsPerMinute, musicbrainzRequestsPerSecond, concurrentAPICalls
        case concurrentApiCalls
    }

    public init() {
        // Defaults are set on stored properties so callers can build rate-limit config incrementally.
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DecodingKeys.self)
        discogsRequestsPerMinute = try container.decodeIfPresent(
            Int.self,
            forKey: .discogsRequestsPerMinute
        ) ?? 55
        musicbrainzRequestsPerSecond = try container.decodeIfPresent(
            Double.self,
            forKey: .musicbrainzRequestsPerSecond
        ) ?? 1.0
        concurrentAPICalls = try container.decodeIfPresent(Int.self, forKey: .concurrentAPICalls)
            ?? container.decodeIfPresent(Int.self, forKey: .concurrentApiCalls)
            ?? 2
    }
}

public struct APIAuthConfig: Sendable, Codable {
    public static let defaultDiscogsBaseHost = "api.discogs.com"
    public static let defaultDiscogsBaseURL: URL = {
        guard let url = makeDiscogsBaseURL(host: defaultDiscogsBaseHost) else {
            preconditionFailure("Default Discogs API host must be valid")
        }
        return url
    }()

    public var discogsTokenReference: String = "${DISCOGS_TOKEN}"
    public var discogsBaseHost: String = Self.defaultDiscogsBaseHost
    public var musicBrainzAppName: String = "MusicGenreUpdater/2.0"
    public var contactEmailReference: String = "${CONTACT_EMAIL}"

    public init() {
        // Defaults are set on stored properties; custom decoding below accepts legacy and current host keys.
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        discogsTokenReference = try container.decodeIfPresent(
            String.self,
            forKey: .discogsTokenReference
        ) ?? container.decodeIfPresent(
            String.self,
            forKey: .discogsToken
        ) ?? container.decodeIfPresent(
            String.self,
            forKey: .legacyDiscogsToken
        ) ?? "${DISCOGS_TOKEN}"
        if let configuredDiscogsBaseHost = try container.decodeIfPresent(
            String.self,
            forKey: .discogsBaseHost
        ) {
            discogsBaseHost = try Self.decodeDiscogsBaseHost(
                configuredDiscogsBaseHost,
                forKey: .discogsBaseHost,
                in: container
            )
        } else if let legacyDiscogsBaseHost = try container.decodeIfPresent(
            String.self,
            forKey: .legacyDiscogsBaseHost
        ) {
            discogsBaseHost = try Self.decodeDiscogsBaseHost(
                legacyDiscogsBaseHost,
                forKey: .legacyDiscogsBaseHost,
                in: container
            )
        } else {
            discogsBaseHost = Self.defaultDiscogsBaseHost
        }
        musicBrainzAppName = try container.decodeIfPresent(
            String.self,
            forKey: .musicBrainzAppName
        ) ?? container.decodeIfPresent(
            String.self,
            forKey: .musicbrainzAppName
        ) ?? container.decodeIfPresent(
            String.self,
            forKey: .legacyMusicBrainzAppName
        ) ?? "MusicGenreUpdater/2.0"
        contactEmailReference = try container.decodeIfPresent(
            String.self,
            forKey: .contactEmailReference
        ) ?? container.decodeIfPresent(
            String.self,
            forKey: .contactEmail
        ) ?? container.decodeIfPresent(
            String.self,
            forKey: .legacyContactEmail
        ) ?? "${CONTACT_EMAIL}"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(discogsTokenReference, forKey: .discogsTokenReference)
        try container.encode(discogsBaseHost, forKey: .discogsBaseHost)
        try container.encode(musicBrainzAppName, forKey: .musicBrainzAppName)
        try container.encode(contactEmailReference, forKey: .contactEmailReference)
    }

    public var discogsBaseURL: URL {
        Self.makeDiscogsBaseURL(host: discogsBaseHost) ?? Self.defaultDiscogsBaseURL
    }

    public static func normalizedDiscogsBaseHost(_ host: String) -> String? {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedHost.isEmpty else { return nil }
        guard !normalizedHost.contains("://"),
              !normalizedHost.contains("/"),
              !normalizedHost.contains("?"),
              !normalizedHost.contains("#"),
              !normalizedHost.contains(":")
        else {
            return nil
        }
        guard !isBlockedLocalHost(normalizedHost),
              !isPrivateIPv4Literal(normalizedHost)
        else {
            return nil
        }
        let hostPattern = #"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$"#
        guard normalizedHost.range(of: hostPattern, options: .regularExpression) != nil else {
            return nil
        }
        guard normalizedHost.split(separator: ".").last?.contains(where: \.isLetter) == true else {
            return nil
        }
        guard isAllowedDiscogsHost(normalizedHost) else {
            return nil
        }
        return normalizedHost
    }

    public static func makeDiscogsBaseURL(host: String) -> URL? {
        guard let normalizedHost = normalizedDiscogsBaseHost(host) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = normalizedHost
        return components.url
    }

    private enum CodingKeys: String, CodingKey {
        case discogsTokenReference, discogsBaseHost, musicBrainzAppName, contactEmailReference
        case discogsToken
        case musicbrainzAppName
        case contactEmail
        case legacyDiscogsToken = "discogs_token"
        case legacyMusicBrainzAppName = "musicbrainz_app_name"
        case legacyContactEmail = "contact_email"
        case legacyDiscogsBaseHost = "discogs_base_host"
    }

    private static func decodeDiscogsBaseHost(
        _ host: String,
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> String {
        guard let normalizedHost = normalizedDiscogsBaseHost(host) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: """
                Discogs API host must be api.discogs.com or a discogs.com subdomain without scheme, \
                path, port, or local/private address.
                """
            )
        }
        return normalizedHost
    }

    private static func isBlockedLocalHost(_ host: String) -> Bool {
        // "localhost.localdomain" is a conventional local hostname alias.
        host == "localhost" || host == "localhost.localdomain" || host.hasSuffix(".local")
    }

    private static func isAllowedDiscogsHost(_ host: String) -> Bool {
        host == defaultDiscogsBaseHost || host.hasSuffix(".discogs.com")
    }

    private static func isPrivateIPv4Literal(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }

        return switch (octets[0], octets[1]) {
        case (0, _), (10, _), (127, _):
            true
        case (100, 64 ... 127), (169, 254), (172, 16 ... 31), (192, 168):
            true
        default:
            false
        }
    }
}

public struct YearLogicConfig: Sendable, Codable {
    public var minValidYear: Int = 1900
    public var absurdYearThreshold: Int = 1970
    public var suspicionThresholdYears: Int = 10
    public var definitiveScoreThreshold: Int = 50
    public var definitiveScoreDiff: Int = 15
    public var minConfidenceForNewYear: Double = 30
    public var preferredCountries: [String] = ["us", "gb", "de", "fr", "jp"]
    public var majorMarketCodes: [String] = ["us", "gb", "uk", "de", "jp", "fr", "ca", "au"]
    public var dominantYearMinConfidence: Double = 0.8

    public init() {
        // Defaults mirror the Python scoring thresholds and can be overridden from configuration files.
    }
}

public struct ScoringConfig: Sendable, Codable {
    public var baseScore: Int = 10
    public var artistExactMatchBonus: Int = 20
    public var artistSubstringPenalty: Int = -20
    public var artistCrossScriptPenalty: Int = -10
    public var artistMismatchPenalty: Int = -60

    public var albumExactMatchBonus: Int = 25
    public var perfectMatchBonus: Int = 10
    public var albumVariationBonus: Int = 10
    public var albumSubstringPenalty: Int = -5
    public var albumUnrelatedPenalty: Int = -40

    public var soundtrackCompensationBonus: Int = 75

    public var mbReleaseGroupMatchBonus: Int = 50
    public var typeAlbumBonus: Int = 15
    public var typeEPSinglePenalty: Int = -10
    public var typeCompilationLivePenalty: Int = -35
    public var statusOfficialBonus: Int = 10
    public var statusBootlegPenalty: Int = -50
    public var statusPromoPenalty: Int = -20
    public var reissuePenalty: Int = -30

    public var yearDiffPenaltyScale: Int = -5
    public var yearDiffMaxPenalty: Int = -40

    public var yearBeforeStartPenalty: Int = -35
    public var yearAfterEndPenalty: Int = -25
    public var yearNearStartBonus: Int = 20

    public var countryArtistMatchBonus: Int = 10
    public var countryMajorMarketBonus: Int = 5

    public var sourceMBBonus: Int = 25
    public var sourceDiscogsBonus: Int = 2
    public var sourceITunesBonus: Int = -10

    public var futureYearPenalty: Int = -10
    public var currentYearPenalty: Int = 0

    public init() {
        // Defaults encode the baseline year-scoring weights used when config omits this section.
    }
}

public struct ReissueDetectionConfig: Sendable, Codable {
    public var reissueKeywords: [String] = ["reissue", "remaster", "remastered"]

    public init() {
        // Defaults keep common reissue markers available when config omits this section.
    }
}

public struct FallbackConfig: Sendable, Codable {
    public var enabled: Bool = true
    public var yearDifferenceThreshold: Int = 5
    public var trustAPIScoreThreshold: Double = 70
    public var maxVerificationAttempts: Int = 3

    public init() {
        // Defaults keep fallback verification enabled with conservative thresholds.
    }
}

public struct ITunesSearchConfig: Sendable, Codable, Equatable {
    public var countryCode: String = "US"
    public var entity: String = "album"
    public var limit: Int = 200
    public var lookupFallbackEnabled: Bool = true

    public init() {
        // Defaults match the public iTunes Search API album lookup limits used by the workflow.
    }

    public var normalizedCountryCode: String {
        let trimmed = countryCode.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "US" : trimmed.uppercased()
    }

    public var clampedLimit: Int {
        min(max(limit, 1), 200)
    }
}

public struct ScriptAPIPriority: Sendable, Codable {
    public var primary: [String]
    public var fallback: [String] = []

    public init(primary: [String], fallback: [String] = []) {
        self.primary = primary
        self.fallback = fallback
    }
}
