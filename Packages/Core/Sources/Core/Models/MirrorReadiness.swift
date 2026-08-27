import Foundation

/// Why persisted processing evidence cannot be treated as current.
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

/// Versioned identifier for the processing metadata contract covered by a scope certificate.
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

/// Observed membership facts covered by one scope certificate.
public struct ScopeEvidence: Codable, Equatable, Hashable, Sendable {
    public let requestedFingerprint: String
    public let observedFingerprint: String
    public let trackCount: Int

    public init(
        requestedFingerprint: String,
        observedFingerprint: String,
        trackCount: Int
    ) {
        self.requestedFingerprint = requestedFingerprint
        self.observedFingerprint = observedFingerprint
        self.trackCount = trackCount
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

    public var evidence: ScopeEvidence {
        ScopeEvidence(
            requestedFingerprint: requestedFingerprint,
            observedFingerprint: observedFingerprint,
            trackCount: trackCount
        )
    }

    public init(
        id: UUID,
        revision: MirrorRevision,
        membership: MembershipStamp,
        testArtists: [String],
        fieldSet: MirrorFieldSet,
        evidence: ScopeEvidence,
        observedAt: Date
    ) {
        self.id = id
        self.revision = revision
        self.membership = membership
        normalizedTestArtists = MirrorRequirement.normalizedArtists(testArtists)
        self.fieldSet = fieldSet
        requestedFingerprint = evidence.requestedFingerprint
        observedFingerprint = evidence.observedFingerprint
        trackCount = evidence.trackCount
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
        guard let currentMembership = try? MembershipFingerprint.make(ids: Array(presentIDs)),
              currentMembership == membershipStamp
        else {
            return .stale(.membershipChanged)
        }
        guard certificate.revision <= revision else {
            return .stale(.supersededRevision)
        }
        guard let scopedIDs = canonicalScopedIDs(for: requirement) else {
            let canonicalIDs = Set(presentTracks.compactMap(\.databaseID))
            let missingCount = presentIDs.subtracting(canonicalIDs).count
            return .incomplete(.identityMissing(count: max(1, missingCount)))
        }
        guard certificate.requestedFingerprint == certificate.observedFingerprint else {
            return .incomplete(.metadataMissing(count: max(1, certificate.trackCount)))
        }
        guard let scopedFingerprint = try? MembershipFingerprint.make(ids: Array(scopedIDs)).fingerprint,
              certificate.trackCount == scopedIDs.count,
              certificate.observedFingerprint == scopedFingerprint
        else {
            return .incomplete(.metadataMissing(count: max(1, scopedIDs.count)))
        }
        if let temporalState = temporalState(for: certificate, requirement: requirement, at: date) {
            return temporalState
        }
        return .ready(certificate)
    }

    private func temporalState(
        for certificate: ScopeCertificate,
        requirement: MirrorRequirement,
        at date: Date
    ) -> MirrorReadiness? {
        if let maximumAge = requirement.maximumMetadataAge,
           !maximumAge.isFinite || maximumAge < 0 {
            return .unavailable(MirrorFailure(
                category: .storage,
                detail: "Maximum metadata age must be finite and non-negative"
            ))
        }
        let observationAge = date.timeIntervalSince(certificate.observedAt)
        guard observationAge.isFinite else {
            return .unavailable(MirrorFailure(
                category: .storage,
                detail: "Mirror observation age must be finite"
            ))
        }
        guard observationAge >= 0 else {
            return .unavailable(MirrorFailure(
                category: .storage,
                detail: "Mirror observation timestamp is in the future"
            ))
        }
        guard let maximumAge = requirement.maximumMetadataAge,
              observationAge >= maximumAge
        else { return nil }
        return .stale(.metadataExpired)
    }

    private func canonicalScopedIDs(for requirement: MirrorRequirement) -> Set<MusicDatabaseTrackID>? {
        var tracksByID: [MusicDatabaseTrackID: Track] = [:]
        for track in presentTracks {
            guard let databaseID = track.databaseID,
                  track.id == databaseID.rawValue,
                  presentIDs.contains(databaseID),
                  tracksByID.updateValue(track, forKey: databaseID) == nil
            else { return nil }
        }
        if requirement.normalizedTestArtists.isEmpty {
            guard Set(tracksByID.keys) == presentIDs else { return nil }
            return presentIDs
        }

        return Set(tracksByID.compactMap { databaseID, track in
            let effectiveArtist = track.albumArtist.flatMap(ArtistAllowList.normalizedName)
                ?? ArtistAllowList.normalizedName(track.artist)
            guard let effectiveArtist,
                  ArtistAllowList.containsNormalized(effectiveArtist, in: requirement.normalizedTestArtists)
            else { return nil }
            return databaseID
        })
    }

    private static func artistsMatch(_ first: [String], _ second: [String]) -> Bool {
        guard first.count == second.count else { return false }
        return zip(first, second).allSatisfy {
            $0.localizedCaseInsensitiveCompare($1) == .orderedSame
        }
    }
}
