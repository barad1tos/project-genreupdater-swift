// YearTypes.swift — Shared types for year scoring, validation, and determination
// Used by: YearScorer, YearValidator, YearFallbackStrategy, YearDeterminator

import Foundation

// MARK: - Enums

/// API data source for release metadata.
public enum APISource: String, Sendable, Codable, CaseIterable, Hashable {
    case musicBrainz = "musicbrainz"
    case discogs
    case itunes
    case unknown
}

/// Type classification for a music release.
public enum ReleaseType: String, Sendable, Codable, CaseIterable {
    case album
    case ep
    case single
    case compilation
    case live
    case soundtrack
    case remix
    case other
}

/// Publication status of a release.
public enum ReleaseStatus: String, Sendable, Codable, CaseIterable {
    case official
    case bootleg
    case promotional
    case pseudoRelease = "pseudo-release"
    case other
}

/// Source that determined a year value.
public enum YearSource: String, Sendable, Codable, Equatable {
    case api
    case library
    case dominant
    case consensus
    case fallback
    case manual
}

/// Result of year validation.
public enum YearValidation: Sendable, Equatable {
    case valid
    case absurd(reason: String)
    case future(reason: String)
    case suspicious(reason: String)
}

/// Decision from the fallback strategy.
public enum FallbackDecision: Sendable, Equatable {
    case useAPIYear(year: Int, confidence: Int)
    case keepExisting(reason: String)
    case escalateToVerification(reason: String)
    case markAndSkip(reason: String)
    case noAction(reason: String)
}

/// Persisted verification reasons emitted by year determination.
public enum YearVerificationReason: String, Sendable, Codable, Equatable {
    case absurdYearWithoutExisting = "absurd_year_no_existing"
    case implausibleExistingYear = "implausible_existing_year"
    case implausibleMatchingYear = "implausible_matching_year"
    case implausibleProposedYear = "implausible_proposed_year"
    case noYearFound = "no_year_found"
    case specialCompilation = "special_album_compilation"
    case specialReissue = "special_album_reissue"
    case specialAlbum = "special_album_special"
    case suspiciousYearChange = "suspicious_year_change"
    case veryLowConfidenceWithoutExisting = "very_low_confidence_no_existing"
}

/// A pending-verification state change produced by year determination.
public enum YearVerificationMutation: Sendable, Equatable {
    case mark(reason: YearVerificationReason, metadata: [String: String])
    case remove
}

// MARK: - Release Candidate

/// A release candidate from an external API, ready for scoring.
public struct ReleaseCandidate: Sendable, Equatable {
    public let artist: String
    public let album: String
    public let year: Int
    public let source: APISource
    public let releaseType: ReleaseType
    public let status: ReleaseStatus
    public let country: String?
    public let isReissue: Bool
    public let mbReleaseGroupID: String?
    public let mbReleaseGroupFirstYear: Int?
    public let genre: String?

    public init(
        artist: String,
        album: String,
        year: Int,
        source: APISource,
        releaseType: ReleaseType = .album,
        status: ReleaseStatus = .official,
        country: String? = nil,
        isReissue: Bool = false,
        mbReleaseGroupID: String? = nil,
        mbReleaseGroupFirstYear: Int? = nil,
        genre: String? = nil
    ) {
        self.artist = artist
        self.album = album
        self.year = year
        self.source = source
        self.releaseType = releaseType
        self.status = status
        self.country = country
        self.isReissue = isReissue
        self.mbReleaseGroupID = mbReleaseGroupID
        self.mbReleaseGroupFirstYear = mbReleaseGroupFirstYear
        self.genre = genre
    }
}

// MARK: - Score Breakdown

/// Breakdown of individual scoring factor contributions.
public struct ScoreBreakdown: Sendable, Equatable {
    public var base: Int = 0
    public var artistMatch: Int = 0
    public var albumMatch: Int = 0
    public var soundtrackCompensation: Int = 0
    public var releaseGroupMatch: Int = 0
    public var releaseType: Int = 0
    public var releaseStatus: Int = 0
    public var reissuePenalty: Int = 0
    public var yearDiff: Int = 0
    public var artistPeriod: Int = 0
    public var country: Int = 0
    public var sourceReliability: Int = 0
    public var futureYearPenalty: Int = 0
    public var currentYearPenalty: Int = 0

    public var totalScore: Int {
        base + artistMatch + albumMatch + soundtrackCompensation
            + releaseGroupMatch + releaseType + releaseStatus
            + reissuePenalty + yearDiff + artistPeriod
            + country + sourceReliability + futureYearPenalty
            + currentYearPenalty
    }

    public init() {}
}

// MARK: - Scored Release

/// A release candidate with its computed score and breakdown.
public struct ScoredRelease: Sendable, Equatable {
    public let candidate: ReleaseCandidate
    public let totalScore: Int
    public let breakdown: ScoreBreakdown

    public init(candidate: ReleaseCandidate, totalScore: Int, breakdown: ScoreBreakdown) {
        self.candidate = candidate
        self.totalScore = totalScore
        self.breakdown = breakdown
    }
}

// MARK: - Dominant Year Result

/// Result of dominant year analysis across album tracks.
public struct DominantYearResult: Sendable, Equatable {
    public let year: Int
    public let confidence: Double
    public let trackCount: Int
    public let totalTracks: Int
    public let isSuspicious: Bool

    public init(year: Int, confidence: Double, trackCount: Int, totalTracks: Int, isSuspicious: Bool = false) {
        self.year = year
        self.confidence = confidence
        self.trackCount = trackCount
        self.totalTracks = totalTracks
        self.isSuspicious = isSuspicious
    }
}

// MARK: - Fallback Context

/// Context provided to the fallback strategy for decision-making.
public struct FallbackContext: Sendable {
    public let scoredReleases: [ScoredRelease]
    public let existingYear: Int?
    public let track: Track
    public let albumTracks: [Track]
    public let isDefinitive: Bool
    public let bestScore: Int
    public let bestYear: Int?
    public let albumTypeInfo: AlbumTypeInfo?
    public let verificationAttempts: Int
    public let releaseYear: Int?
    public let artistStartYear: Int?
    public let decisionYear: Int
    public let yearScores: [Int: Int]

    public init(
        scoredReleases: [ScoredRelease],
        existingYear: Int?,
        track: Track,
        albumTracks: [Track],
        isDefinitive: Bool,
        bestScore: Int,
        bestYear: Int?,
        albumTypeInfo: AlbumTypeInfo? = nil,
        verificationAttempts: Int = 0,
        releaseYear: Int? = nil,
        artistStartYear: Int? = nil,
        decisionYear: Int = Calendar.current.component(.year, from: Date()),
        yearScores: [Int: Int] = [:]
    ) {
        self.scoredReleases = scoredReleases
        self.existingYear = existingYear
        self.track = track
        self.albumTracks = albumTracks
        self.isDefinitive = isDefinitive
        self.bestScore = bestScore
        self.bestYear = bestYear
        self.albumTypeInfo = albumTypeInfo
        self.verificationAttempts = verificationAttempts
        self.releaseYear = releaseYear
        self.artistStartYear = artistStartYear
        self.decisionYear = decisionYear
        self.yearScores = yearScores
    }
}

/// Final fallback projection before Services applies persistence side effects.
public struct YearFallbackOutcome: Sendable, Equatable {
    public let decision: FallbackDecision
    public let year: Int?
    public let source: YearSource
    public let verification: YearVerificationMutation?

    public init(
        decision: FallbackDecision,
        year: Int?,
        source: YearSource,
        verification: YearVerificationMutation? = nil
    ) {
        self.decision = decision
        self.year = year
        self.source = source
        self.verification = verification
    }
}

// MARK: - Year Determination Result

/// Extended result from year determination including scoring details.
public struct YearDeterminationResult: Sendable {
    public let yearResult: YearResult
    public let scoredYearResult: YearResult?
    public let source: YearSource
    public let breakdown: ScoreBreakdown?
    public let fallbackDecision: FallbackDecision?
    public let candidateCount: Int
    public let acceptedCandidateYears: [Int]
    public let rejectedCandidateYears: [Int]
    public let verificationMutations: [YearVerificationMutation]

    public init(
        yearResult: YearResult,
        scoredYearResult: YearResult? = nil,
        source: YearSource,
        breakdown: ScoreBreakdown? = nil,
        fallbackDecision: FallbackDecision? = nil,
        candidateCount: Int = 0,
        acceptedCandidateYears: [Int] = [],
        rejectedCandidateYears: [Int] = [],
        verificationMutations: [YearVerificationMutation] = []
    ) {
        self.yearResult = yearResult
        self.scoredYearResult = scoredYearResult
        self.source = source
        self.breakdown = breakdown
        self.fallbackDecision = fallbackDecision
        self.candidateCount = candidateCount
        self.acceptedCandidateYears = acceptedCandidateYears
        self.rejectedCandidateYears = rejectedCandidateYears
        self.verificationMutations = verificationMutations
    }
}
