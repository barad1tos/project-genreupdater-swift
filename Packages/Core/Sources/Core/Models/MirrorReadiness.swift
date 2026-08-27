import Foundation

/// Why a previously complete processing mirror is no longer current.
public enum StaleMirrorReason: Equatable, Sendable {
    case membershipChanged
    case metadataExpired
    case supersededRevision
}

/// Why the current mirror cannot yet authorize processing.
public enum IncompleteMirrorReason: Equatable, Sendable {
    case freshObservationRequired
    case identityMissing(count: Int)
    case metadataMissing(count: Int)
    case narrowedObservation
}

/// Persistence or observation boundary that made mirror readiness unavailable.
public enum MirrorFailureCategory: String, Codable, Equatable, Sendable {
    case migration
    case observation
    case storage
}

/// A typed mirror-read failure that can be surfaced without granting processing authority.
public struct MirrorFailure: Equatable, Sendable {
    public let category: MirrorFailureCategory
    public let detail: String

    public init(category: MirrorFailureCategory, detail: String) {
        self.category = category
        self.detail = detail
    }
}

/// Processing admission derived from persisted scope evidence.
public enum MirrorReadiness: Equatable, Sendable {
    case ready(ScopeCertificate)
    case stale(StaleMirrorReason)
    case incomplete(IncompleteMirrorReason)
    case unavailable(MirrorFailure)

    public var isReady: Bool {
        if case .ready = self {
            return true
        }
        return false
    }
}

/// Versioned processing metadata contract proven by a scope certificate.
public struct MirrorFieldSet: Codable, Equatable, Hashable, Sendable {
    public static let processingV1 = Self(version: 1)

    public let version: UInt16

    public init(version: UInt16) {
        self.version = version
    }
}

/// Exact processing evidence required by one caller.
public struct MirrorRequirement: Equatable, Sendable {
    public let normalizedTestArtists: [String]
    public let fieldSet: MirrorFieldSet
    public let maximumMetadataAge: TimeInterval?

    public init(
        testArtists: [String],
        fieldSet: MirrorFieldSet,
        maximumMetadataAge: TimeInterval?
    ) {
        normalizedTestArtists = Self.normalizedArtists(testArtists)
        self.fieldSet = fieldSet
        self.maximumMetadataAge = maximumMetadataAge
    }

    fileprivate static func normalizedArtists(_ artists: [String]) -> [String] {
        ArtistAllowList.normalized(artists).sorted { first, second in
            let comparison = first.localizedCaseInsensitiveCompare(second)
            return comparison == .orderedSame ? first < second : comparison == .orderedAscending
        }
    }
}

/// Evidence that one exact processing scope is complete at a committed mirror revision.
public struct ScopeCertificate: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let revision: MirrorRevision
    public let membership: MembershipStamp
    public let normalizedTestArtists: [String]
    public let fieldSet: MirrorFieldSet
    public let requestedFingerprint: String
    public let observedFingerprint: String
    public let trackCount: Int
    public let observedAt: Date

    public init(
        id: UUID,
        revision: MirrorRevision,
        membership: MembershipStamp,
        testArtists: [String],
        fieldSet: MirrorFieldSet,
        requestedFingerprint: String,
        observedFingerprint: String,
        trackCount: Int,
        observedAt: Date
    ) {
        self.id = id
        self.revision = revision
        self.membership = membership
        normalizedTestArtists = MirrorRequirement.normalizedArtists(testArtists)
        self.fieldSet = fieldSet
        self.requestedFingerprint = requestedFingerprint
        self.observedFingerprint = observedFingerprint
        self.trackCount = trackCount
        self.observedAt = observedAt
    }
}

/// One coherent read of current library membership, repair input, and scope evidence.
public struct TrackMirrorSnapshot: Equatable, Sendable {
    public let revision: MirrorRevision
    public let membershipStamp: MembershipStamp
    public let presentIDs: Set<MusicDatabaseTrackID>
    public let presentTracks: [Track]
    public let repairCandidates: [Track]
    public let certificates: [ScopeCertificate]

    public init(
        revision: MirrorRevision,
        membershipStamp: MembershipStamp,
        presentIDs: Set<MusicDatabaseTrackID>,
        presentTracks: [Track],
        repairCandidates: [Track],
        certificates: [ScopeCertificate]
    ) {
        self.revision = revision
        self.membershipStamp = membershipStamp
        self.presentIDs = presentIDs
        self.presentTracks = presentTracks
        self.repairCandidates = repairCandidates
        self.certificates = certificates
    }

    public func readiness(for requirement: MirrorRequirement, at date: Date = Date()) -> MirrorReadiness {
        let matchingScope = certificates.filter { certificate in
            certificate.fieldSet == requirement.fieldSet
                && Self.artistsMatch(
                    certificate.normalizedTestArtists,
                    requirement.normalizedTestArtists
                )
        }
        guard !matchingScope.isEmpty else {
            return .incomplete(.freshObservationRequired)
        }
        guard let certificate = matchingScope.first(where: { $0.membership == membershipStamp }) else {
            return .stale(.membershipChanged)
        }
        guard certificate.revision <= revision else {
            return .stale(.supersededRevision)
        }
        guard certificate.requestedFingerprint == certificate.observedFingerprint else {
            return .incomplete(.metadataMissing(count: max(1, certificate.trackCount)))
        }
        if let maximumAge = requirement.maximumMetadataAge,
           date.timeIntervalSince(certificate.observedAt) > maximumAge {
            return .stale(.metadataExpired)
        }
        return .ready(certificate)
    }

    private static func artistsMatch(_ first: [String], _ second: [String]) -> Bool {
        guard first.count == second.count else { return false }
        return zip(first, second).allSatisfy {
            $0.localizedCaseInsensitiveCompare($1) == .orderedSame
        }
    }
}
