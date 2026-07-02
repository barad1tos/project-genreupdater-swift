import Core
import Foundation

public enum ProcessingScopeSource: String, Codable, Equatable, Sendable {
    case fullLibrary
    case testArtists
}

public struct ProcessingScopeSnapshot: Codable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let source: ProcessingScopeSource
    public let normalizedTestArtists: [String]
    public let matchingRule: String
    public let knownTrackCount: Int?
    public let fingerprint: String
    public let reason: String

    public init(
        id: UUID = UUID(),
        createdAt: Date,
        source: ProcessingScopeSource,
        normalizedTestArtists: [String],
        matchingRule: String,
        knownTrackCount: Int?,
        fingerprint: String,
        reason: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
        self.normalizedTestArtists = normalizedTestArtists
        self.matchingRule = matchingRule
        self.knownTrackCount = knownTrackCount
        self.fingerprint = fingerprint
        self.reason = reason
    }

    public static func capture(
        requestedTestArtists: [String],
        knownTrackCount: Int?,
        createdAt: Date,
        reason: String
    ) -> Self {
        let normalizedArtists = ArtistAllowList.normalized(requestedTestArtists)
        let source: ProcessingScopeSource = normalizedArtists.isEmpty ? .fullLibrary : .testArtists
        let artistFingerprint = normalizedArtists
            .map { $0.lowercased() }
            .joined(separator: "|")
        let trackCountFingerprint = knownTrackCount.map(String.init) ?? "unknown"

        return Self(
            createdAt: createdAt,
            source: source,
            normalizedTestArtists: normalizedArtists,
            matchingRule: "Core.ArtistAllowList.effectiveArtist.localizedCaseInsensitiveCompare",
            knownTrackCount: knownTrackCount,
            fingerprint: "\(source.rawValue):\(artistFingerprint):tracks=\(trackCountFingerprint)",
            reason: reason
        )
    }
}
