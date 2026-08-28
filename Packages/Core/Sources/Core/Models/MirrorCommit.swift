import Foundation

/// Opaque identity of one source observation; `MirrorCommit.baseRevision` is the revision fence.
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
    case narrowedObservation
}

/// Requested certificate transition; rebases require proof and unsupported transitions are rejected by the store.
public enum CertificateChange: Equatable, Sendable {
    case preserve
    case replace(ScopeCertificate)
    case invalidate(InvalidationReason)
    case rebase(ScopeCertificate)
}

/// An atomic mirror mutation accepted only when its base revision and certificate transition are valid.
public struct MirrorCommit: Sendable {
    public let baseRevision: MirrorRevision
    public let observation: ObservationID
    public let inventoryChange: InventoryChange
    public let repairs: [TrackMirrorRepair]
    public let upserts: [Track]
    public let certificates: CertificateChange

    public init(
        baseRevision: MirrorRevision,
        observation: ObservationID = ObservationID(),
        inventoryChange: InventoryChange,
        repairs: [TrackMirrorRepair],
        upserts: [Track],
        certificates: CertificateChange
    ) {
        self.baseRevision = baseRevision
        self.observation = observation
        self.inventoryChange = inventoryChange
        self.repairs = repairs
        self.upserts = upserts
        self.certificates = certificates
    }
}

/// Stable revision result of a successful mirror commit.
public struct MirrorCommitResult: Equatable, Sendable {
    public let revision: MirrorRevision

    public init(revision: MirrorRevision) {
        self.revision = revision
    }
}
