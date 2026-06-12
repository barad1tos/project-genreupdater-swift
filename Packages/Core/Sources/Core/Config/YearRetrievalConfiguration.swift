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

    /// API priority per script type (e.g., "latin" -> prefer musicbrainz).
    public var scriptAPIPriorities: [String: ScriptAPIPriority] = [:]

    private enum CodingKeys: String, CodingKey {
        case enabled, preferredAPI, apiAuth, rateLimits, logic, reissueDetection, scoring, fallback
        case scriptAPIPriorities
    }

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        preferredAPI = try container.decodeIfPresent(PreferredAPI.self, forKey: .preferredAPI) ?? .musicbrainz
        apiAuth = try container.decodeIfPresent(APIAuthConfig.self, forKey: .apiAuth) ?? APIAuthConfig()
        rateLimits = try container.decodeIfPresent(APIRateLimits.self, forKey: .rateLimits) ?? APIRateLimits()
        logic = try container.decodeIfPresent(YearLogicConfig.self, forKey: .logic) ?? YearLogicConfig()
        reissueDetection = try container
            .decodeIfPresent(ReissueDetectionConfig.self, forKey: .reissueDetection) ?? ReissueDetectionConfig()
        scoring = try container.decodeIfPresent(ScoringConfig.self, forKey: .scoring) ?? ScoringConfig()
        fallback = try container.decodeIfPresent(FallbackConfig.self, forKey: .fallback) ?? FallbackConfig()
        scriptAPIPriorities = try container.decodeIfPresent(
            [String: ScriptAPIPriority].self,
            forKey: .scriptAPIPriorities
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

    public init() {}
}

public struct APIAuthConfig: Sendable, Codable {
    public var discogsTokenReference: String = "${DISCOGS_TOKEN}"
    public var musicBrainzAppName: String = "MusicGenreUpdater/2.0"
    public var contactEmailReference: String = "${CONTACT_EMAIL}"

    public init() {}
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

    public init() {}
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

    public init() {}
}

public struct ReissueDetectionConfig: Sendable, Codable {
    public var reissueKeywords: [String] = ["reissue", "remaster", "remastered"]

    public init() {}
}

public struct FallbackConfig: Sendable, Codable {
    public var enabled: Bool = true
    public var yearDifferenceThreshold: Int = 5
    public var trustAPIScoreThreshold: Double = 70
    public var maxVerificationAttempts: Int = 3

    public init() {}
}

public struct ScriptAPIPriority: Sendable, Codable {
    public var primary: [String]
    public var fallback: [String] = []

    public init(primary: [String], fallback: [String] = []) {
        self.primary = primary
        self.fallback = fallback
    }
}
