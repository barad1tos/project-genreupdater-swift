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

/// Source-read mode captured for one durable mirror synchronization.
public enum MirrorSyncMode: String, Codable, Equatable, Sendable {
    case fast
    case force
    case membershipOnly
}

/// Terminal result of a synchronization record stored with its mirror commit.
public enum MirrorSyncOutcome: String, Codable, Equatable, Sendable {
    case committed
}

/// Delta counts stored without duplicating track metadata in the synchronization audit trail.
public struct MirrorSyncCounts: Codable, Equatable, Sendable {
    public let new: Int
    public let modified: Int
    public let identityChanged: Int
    public let refreshed: Int
    public let removed: Int

    public init(new: Int, modified: Int, identityChanged: Int, refreshed: Int, removed: Int) {
        self.new = new
        self.modified = modified
        self.identityChanged = identityChanged
        self.refreshed = refreshed
        self.removed = removed
    }
}

/// Revision fence captured around one committed synchronization.
public struct MirrorSyncRevisions: Codable, Equatable, Sendable {
    public let base: MirrorRevision
    public let committed: MirrorRevision

    public init(base: MirrorRevision, committed: MirrorRevision) {
        self.base = base
        self.committed = committed
    }
}

/// Scope and membership evidence authorized by one committed synchronization.
public struct MirrorSyncEvidence: Codable, Equatable, Sendable {
    public let membership: MembershipStamp
    public let scopeID: UUID
    public let certificateID: UUID?

    public init(membership: MembershipStamp, scopeID: UUID, certificateID: UUID?) {
        self.membership = membership
        self.scopeID = scopeID
        self.certificateID = certificateID
    }
}

/// Wall-clock bounds of one synchronization attempt.
public struct MirrorSyncWindow: Codable, Equatable, Sendable {
    public let startedAt: Date
    public let completedAt: Date

    public init(startedAt: Date, completedAt: Date) {
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

/// Requested and observed source coverage stored without duplicating source rows.
public struct MirrorSyncCoverage: Codable, Equatable, Sendable {
    public let identityRequestedCount: Int
    public let identityObservedCount: Int
    public let metadataRequestedCount: Int
    public let metadataObservedCount: Int
    public let isMembershipComplete: Bool
    public let isIdentityComplete: Bool
    public let isMetadataComplete: Bool

    public init(
        identityRequestedCount: Int,
        identityObservedCount: Int,
        metadataRequestedCount: Int,
        metadataObservedCount: Int,
        isMembershipComplete: Bool,
        isIdentityComplete: Bool,
        isMetadataComplete: Bool
    ) {
        self.identityRequestedCount = identityRequestedCount
        self.identityObservedCount = identityObservedCount
        self.metadataRequestedCount = metadataRequestedCount
        self.metadataObservedCount = metadataObservedCount
        self.isMembershipComplete = isMembershipComplete
        self.isIdentityComplete = isIdentityComplete
        self.isMetadataComplete = isMetadataComplete
    }
}

/// Immutable evidence for one successful source observation and mirror commit.
public struct MirrorSyncRecord: Codable, Equatable, Sendable {
    public let observation: ObservationID
    public let revisions: MirrorSyncRevisions
    public let evidence: MirrorSyncEvidence
    public let mode: MirrorSyncMode
    public let window: MirrorSyncWindow
    public let delta: MirrorSyncCounts
    public let coverage: MirrorSyncCoverage
    public let outcome: MirrorSyncOutcome

    public init(
        observation: ObservationID,
        revisions: MirrorSyncRevisions,
        evidence: MirrorSyncEvidence,
        mode: MirrorSyncMode,
        window: MirrorSyncWindow,
        delta: MirrorSyncCounts,
        coverage: MirrorSyncCoverage
    ) {
        self.observation = observation
        self.revisions = revisions
        self.evidence = evidence
        self.mode = mode
        self.window = window
        self.delta = delta
        self.coverage = coverage
        outcome = .committed
    }
}

/// An atomic mirror mutation accepted only when its base revision and certificate transition are valid.
public struct MirrorCommit: Sendable {
    public let baseRevision: MirrorRevision
    public let observation: ObservationID
    public let inventoryChange: InventoryChange
    public let repairs: [TrackMirrorRepair]
    public let upserts: [Track]
    public let certificates: CertificateChange
    public let syncRecord: MirrorSyncRecord?

    public init(
        baseRevision: MirrorRevision,
        observation: ObservationID = ObservationID(),
        inventoryChange: InventoryChange,
        repairs: [TrackMirrorRepair],
        upserts: [Track],
        certificates: CertificateChange,
        syncRecord: MirrorSyncRecord? = nil
    ) {
        self.baseRevision = baseRevision
        self.observation = observation
        self.inventoryChange = inventoryChange
        self.repairs = repairs
        self.upserts = upserts
        self.certificates = certificates
        self.syncRecord = syncRecord
    }
}

/// Stable revision result of a successful mirror commit.
public struct MirrorCommitResult: Equatable, Sendable {
    public let revision: MirrorRevision
    /// Exact post-transaction mirror state when the store can return it atomically.
    public let snapshot: TrackMirrorSnapshot?

    public init(revision: MirrorRevision, snapshot: TrackMirrorSnapshot? = nil) {
        self.revision = revision
        self.snapshot = snapshot
    }
}
