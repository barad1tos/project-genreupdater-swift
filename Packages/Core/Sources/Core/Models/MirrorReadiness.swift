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

/// A scope certificate paired with the exact canonical tracks it authorizes for processing.
public struct AdmittedMirror: Equatable, Sendable {
    public let certificate: ScopeCertificate
    public let tracks: [Track]
}

/// Processing admission or the typed readiness state that rejected it.
public enum MirrorAdmissionDecision: Equatable, Sendable {
    case admitted(AdmittedMirror)
    case rejected(MirrorReadiness)
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
    /// Latest mirror revision that changed user-facing projections.
    public let contentRevision: MirrorRevision
    public let membershipStamp: MembershipStamp
    public let presentIDs: Set<MusicDatabaseTrackID>
    public let memberIdentities: [MusicDatabaseTrackID: MemberIdentity]
    public let presentTracks: [Track]
    public let repairCandidates: [Track]
    public let certificates: [ScopeCertificate]

    public init(
        revision: MirrorRevision,
        contentRevision: MirrorRevision? = nil,
        membershipStamp: MembershipStamp,
        presentIDs: Set<MusicDatabaseTrackID>,
        memberIdentities: [MusicDatabaseTrackID: MemberIdentity] = [:],
        presentTracks: [Track],
        repairCandidates: [Track],
        certificates: [ScopeCertificate]
    ) {
        self.revision = revision
        self.contentRevision = contentRevision ?? revision
        self.membershipStamp = membershipStamp
        self.presentIDs = presentIDs
        self.memberIdentities = memberIdentities
        self.presentTracks = presentTracks
        self.repairCandidates = repairCandidates
        self.certificates = certificates
    }

    public func readiness(for requirement: MirrorRequirement, at date: Date = Date()) -> MirrorReadiness {
        switch admission(for: requirement, at: date) {
        case let .admitted(admittedMirror):
            .ready(admittedMirror.certificate)
        case let .rejected(readiness):
            readiness
        }
    }

    public func admission(
        for requirement: MirrorRequirement,
        at date: Date = Date()
    ) -> MirrorAdmissionDecision {
        let matchingScope = certificates.filter { certificate in
            certificate.fieldSet == requirement.fieldSet
                && Self.artistsMatch(
                    certificate.normalizedTestArtists,
                    requirement.normalizedTestArtists
                )
        }
        guard !matchingScope.isEmpty else {
            return .rejected(.incomplete(.freshObservationRequired))
        }
        guard let certificate = matchingScope.first(where: { $0.membership == membershipStamp }) else {
            return .rejected(.stale(.membershipChanged))
        }
        guard let currentMembership = try? MembershipFingerprint.make(ids: Array(presentIDs)),
              currentMembership == membershipStamp
        else {
            return .rejected(.stale(.membershipChanged))
        }
        guard certificate.revision <= revision else {
            return .rejected(.stale(.supersededRevision))
        }
        let scopedTracks: [Track]
        switch resolveScopedTracks(for: requirement) {
        case let .ready(tracks):
            scopedTracks = tracks
        case let .identityMissing(count):
            return .rejected(.incomplete(.identityMissing(count: count)))
        case let .metadataMissing(count):
            return .rejected(.incomplete(.metadataMissing(count: count)))
        }
        let scopedIDs = Set(scopedTracks.compactMap(\.databaseID))
        guard certificate.requestedFingerprint == certificate.observedFingerprint else {
            return .rejected(.incomplete(.metadataMissing(count: max(1, certificate.trackCount))))
        }
        guard let scopedFingerprint = try? MembershipFingerprint.make(ids: Array(scopedIDs)).fingerprint,
              certificate.trackCount == scopedIDs.count,
              certificate.observedFingerprint == scopedFingerprint
        else {
            return .rejected(.incomplete(.metadataMissing(count: max(1, scopedIDs.count))))
        }
        if let temporalState = temporalState(for: certificate, requirement: requirement, at: date) {
            return .rejected(temporalState)
        }
        return .admitted(AdmittedMirror(certificate: certificate, tracks: scopedTracks))
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

    private enum ScopedTrackResolution {
        case ready([Track])
        case identityMissing(count: Int)
        case metadataMissing(count: Int)
    }

    private func resolveScopedTracks(for requirement: MirrorRequirement) -> ScopedTrackResolution {
        var tracksByID: [MusicDatabaseTrackID: Track] = [:]
        for track in presentTracks {
            guard let databaseID = track.databaseID,
                  track.id == databaseID.rawValue,
                  presentIDs.contains(databaseID),
                  tracksByID.updateValue(track, forKey: databaseID) == nil
            else { return .identityMissing(count: 1) }
        }
        if requirement.normalizedTestArtists.isEmpty {
            let missingCount = presentIDs.subtracting(tracksByID.keys).count
            guard missingCount == 0 else { return .identityMissing(count: missingCount) }
            return .ready(tracksByID.sorted { first, second in
                first.key.rawValue < second.key.rawValue
            }.map(\.value))
        }

        let validIdentities = memberIdentities.filter { databaseID, identity in
            presentIDs.contains(databaseID) && databaseID == identity.databaseID
        }
        let missingIdentityCount = presentIDs.subtracting(validIdentities.keys).count
        guard missingIdentityCount == 0, validIdentities.count == memberIdentities.count else {
            return .identityMissing(count: max(1, missingIdentityCount))
        }
        let scopedIDs: Set<MusicDatabaseTrackID> = Set(validIdentities.compactMap { databaseID, identity in
            guard ArtistAllowList.containsNormalized(
                artist: identity.artist,
                albumArtist: identity.albumArtist,
                in: requirement.normalizedTestArtists
            ) else { return nil }
            return databaseID
        })
        let missingMetadataCount = scopedIDs.subtracting(tracksByID.keys).count
        guard missingMetadataCount == 0 else {
            return .metadataMissing(count: missingMetadataCount)
        }
        return .ready(scopedIDs.sorted { $0.rawValue < $1.rawValue }.compactMap { tracksByID[$0] })
    }

    private static func artistsMatch(_ first: [String], _ second: [String]) -> Bool {
        guard first.count == second.count else { return false }
        return zip(first, second).allSatisfy {
            $0.localizedCaseInsensitiveCompare($1) == .orderedSame
        }
    }
}
