import Foundation
@testable import Core

// MARK: - Fixture Loader

enum FixtureLoader {
    static func load<T: Decodable>(_ filename: String) throws -> T {
        guard let url = Bundle.module.url(
            forResource: filename,
            withExtension: "json",
            subdirectory: "Fixtures"
        ) else {
            throw FixtureError.fileNotFound(filename)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    }

    enum FixtureError: Error, CustomStringConvertible {
        case fileNotFound(String)

        var description: String {
            switch self {
            case .fileNotFound(let name):
                "Fixture file not found: \(name).json"
            }
        }
    }
}

// MARK: - Shared

struct TrackFixture: Codable, Sendable {
    let id: String
    let name: String
    let artist: String
    let album: String
    let genre: String?
    let year: String?
    let dateAdded: String?
    let releaseYear: String?
    let albumArtist: String?
    let trackStatus: String?

    func toTrack() -> Track {
        Track(
            id: id,
            name: name,
            artist: artist,
            album: album,
            genre: genre,
            year: year.flatMap { Int($0) },
            dateAdded: dateAdded.flatMap { Self.dateFormatter.date(from: $0) },
            trackStatus: trackStatus,
            releaseYear: releaseYear.flatMap { Int($0) },
            albumArtist: albumArtist
        )
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}

// MARK: - Genre Fixtures

struct GenreFixtureCase: Codable, Sendable {
    let id: String
    let description: String
    let tracks: [TrackFixture]
    let expected: GenreExpected
}

struct GenreExpected: Codable, Sendable {
    let genre: String?
    let sourceAlbum: String?
}

// MARK: - Scoring Fixtures

struct ReleaseFixture: Codable, Sendable {
    let artist: String
    let album: String
    let year: Int
    let source: String
    let releaseType: String
    let status: String
    let country: String?
    let isReissue: Bool
    let mbReleaseGroupID: String?
    let mbReleaseGroupFirstYear: Int?
    let genre: String?

    func toCandidate() -> ReleaseCandidate {
        ReleaseCandidate(
            artist: artist,
            album: album,
            year: year,
            source: APISource(rawValue: source) ?? .unknown,
            releaseType: ReleaseType(rawValue: releaseType) ?? .other,
            status: ReleaseStatus(rawValue: status) ?? .other,
            country: country,
            isReissue: isReissue,
            mbReleaseGroupID: mbReleaseGroupID,
            mbReleaseGroupFirstYear: mbReleaseGroupFirstYear,
            genre: genre
        )
    }
}

struct QueryFixture: Codable, Sendable {
    let artist: String
    let album: String
    let artistRegion: String?
    let artistPeriodStart: Int?
    let artistPeriodEnd: Int?
}

struct ScoringExpected: Codable, Sendable {
    let totalScore: Int
}

struct CandidateFixture: Codable, Sendable {
    let release: ReleaseFixture
    let totalScore: Int
}

struct ScoringFixtureCase: Codable, Sendable {
    let id: String
    let description: String
    let type: String?
    let release: ReleaseFixture?
    let query: QueryFixture
    let expected: ScoringExpected?
    let candidates: [CandidateFixture]?
    let expectedRanking: [String]?

    var isRanking: Bool { type == "ranking" }
}

// MARK: - Resolution Fixtures

struct ResolutionFixtureCase: Codable, Sendable {
    let id: String
    let description: String
    let yearScores: [String: [Int]]
    /// JSON encodes existingYear as a string (e.g. "1983") or null.
    let existingYear: String?
    let expected: ResolutionExpected

    var existingYearInt: Int? {
        existingYear.flatMap { Int($0) }
    }
}

struct ResolutionExpected: Codable, Sendable {
    let year: Int?
    let isDefinitive: Bool
    let confidence: Int
}

// MARK: - Validation Fixtures

struct ValidationFixtureCase: Codable, Sendable {
    let id: String
    let description: String
    let tracks: [TrackFixture]
    let expected: ValidationExpected
}

struct ValidationExpected: Codable, Sendable {
    let dominantYear: Int?
    let mostCommonYear: Int?
    let consensusReleaseYear: Int?
}

// MARK: - Fallback Fixtures

struct FallbackFixtureCase: Codable, Sendable {
    let id: String
    let description: String
    let context: FallbackContextFixture
    let expected: FallbackExpected
}

struct FallbackContextFixture: Codable, Sendable {
    let bestYear: Int?
    let bestScore: Int
    let isDefinitive: Bool
    let existingYear: Int?
    let albumType: String
    let verificationAttempts: Int
}

struct FallbackExpected: Codable, Sendable {
    let decision: String
}

// MARK: - Helpers

enum FixtureHelpers {
    /// Load Python scoring config and create a matching ScoringConfig.
    static func loadPythonScoringConfig() throws -> ScoringConfig {
        try FixtureLoader.load("python_scoring_config")
    }

    /// Compute the most common year from tracks (mode), ignoring 0 and nil.
    /// Python parity: Counter.most_common() preserves insertion order for
    /// equal counts, so we return the first-seen year with the max count.
    static func mostCommonYear(tracks: [Track]) -> Int? {
        let years = tracks.compactMap(\.year).filter { $0 > 0 }
        guard !years.isEmpty else { return nil }
        var counts: [Int: Int] = [:]
        for year in years { counts[year, default: 0] += 1 }
        let maxCount = counts.values.max()!
        return years.first { counts[$0] == maxCount }
    }

    /// Extract the decision type string from a FallbackDecision enum.
    static func decisionType(_ decision: FallbackDecision) -> String {
        switch decision {
        case .useAPIYear:
            "useAPIYear"
        case .keepExisting:
            "keepExisting"
        case .escalateToVerification:
            "escalateToVerification"
        case .markAndSkip:
            "markAndSkip"
        case .noAction:
            "noAction"
        }
    }
}
