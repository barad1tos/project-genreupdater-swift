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
    public let mirrorRevision: MirrorRevision?
    public let certificateID: UUID?

    public init(
        id: UUID = UUID(),
        createdAt: Date,
        source: ProcessingScopeSource,
        normalizedTestArtists: [String],
        matchingRule: String,
        knownTrackCount: Int?,
        fingerprint: String,
        reason: String,
        mirrorRevision: MirrorRevision? = nil,
        certificateID: UUID? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
        self.normalizedTestArtists = normalizedTestArtists
        self.matchingRule = matchingRule
        self.knownTrackCount = knownTrackCount
        self.fingerprint = fingerprint
        self.reason = reason
        self.mirrorRevision = mirrorRevision
        self.certificateID = certificateID
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
        let rule = ArtistAllowList.scopeRuleIdentifier
        let ruleFingerprint = source == .testArtists ? ":rule=\(rule)" : ""

        return Self(
            createdAt: createdAt,
            source: source,
            normalizedTestArtists: normalizedArtists,
            matchingRule: rule,
            knownTrackCount: knownTrackCount,
            fingerprint: "\(source.rawValue):\(artistFingerprint)\(ruleFingerprint):tracks=\(trackCountFingerprint)",
            reason: reason
        )
    }

    func binding(revision: MirrorRevision, certificateID: UUID?) -> Self {
        Self(
            id: id,
            createdAt: createdAt,
            source: source,
            normalizedTestArtists: normalizedTestArtists,
            matchingRule: matchingRule,
            knownTrackCount: knownTrackCount,
            fingerprint: fingerprint,
            reason: reason,
            mirrorRevision: revision,
            certificateID: certificateID
        )
    }

    func isEvidenceBinding(of previous: Self) -> Bool {
        guard previous.mirrorRevision == nil,
              previous.certificateID == nil,
              let mirrorRevision
        else { return false }
        return self == previous.binding(revision: mirrorRevision, certificateID: certificateID)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case source
        case normalizedTestArtists
        case matchingRule
        case knownTrackCount
        case fingerprint
        case reason
        case mirrorRevision
        case certificateID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            source: container.decode(ProcessingScopeSource.self, forKey: .source),
            normalizedTestArtists: container.decode([String].self, forKey: .normalizedTestArtists),
            matchingRule: container.decode(String.self, forKey: .matchingRule),
            knownTrackCount: container.decodeIfPresent(Int.self, forKey: .knownTrackCount),
            fingerprint: container.decode(String.self, forKey: .fingerprint),
            reason: container.decode(String.self, forKey: .reason),
            mirrorRevision: container.decodeIfPresent(MirrorRevision.self, forKey: .mirrorRevision),
            certificateID: container.decodeIfPresent(UUID.self, forKey: .certificateID)
        )
    }
}
