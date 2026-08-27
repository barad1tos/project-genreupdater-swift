import Foundation

/// Identity of one generation-fenced source observation.
public struct ObservationID: Codable, Equatable, Hashable, Sendable {
    public let value: UUID

    public init(value: UUID = UUID()) {
        self.value = value
    }
}

/// Why the current certificate set must stop authorizing processing.
public enum InvalidationReason: Equatable, Sendable {
    case incompleteObservation
    case membershipChanged
    case metadataChanged
    case narrowedObservation
}

/// Explicit certificate transition committed with mirror state.
public enum CertificateChange: Equatable, Sendable {
    case preserve
    case replace(ScopeCertificate)
    case invalidate(InvalidationReason)
    case rebase(ScopeCertificate)
}

/// One coherent mutation of the persisted Music library mirror.
public struct MirrorCommit: Sendable {
    public let baseRevision: MirrorRevision
    public let observation: ObservationID
    public let membershipChange: MembershipChange
    public let repairs: [TrackMirrorRepair]
    public let upserts: [Track]
    public let certificates: CertificateChange

    public init(
        baseRevision: MirrorRevision,
        observation: ObservationID,
        membershipChange: MembershipChange,
        repairs: [TrackMirrorRepair],
        upserts: [Track],
        certificates: CertificateChange
    ) {
        self.baseRevision = baseRevision
        self.observation = observation
        self.membershipChange = membershipChange
        self.repairs = repairs
        self.upserts = upserts
        self.certificates = certificates
    }

    public init(
        baseRevision: MirrorRevision,
        certificates: CertificateChange,
        membershipChange: MembershipChange,
        repairs: [TrackMirrorRepair],
        upserts: [Track],
        observation: ObservationID = ObservationID()
    ) {
        self.init(
            baseRevision: baseRevision,
            observation: observation,
            membershipChange: membershipChange,
            repairs: repairs,
            upserts: upserts,
            certificates: certificates
        )
    }
}

/// Facts currently consumed after a successful mirror commit.
public struct MirrorCommitResult: Equatable, Sendable {
    public let revision: MirrorRevision

    public init(revision: MirrorRevision) {
        self.revision = revision
    }
}
