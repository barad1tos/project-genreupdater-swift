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

/// Scope and membership evidence recorded by one committed synchronization.
/// A non-`nil` certificate ID links the record to processing authorization.
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

/// Wall-clock bounds of one synchronization invocation through commit preparation.
public struct MirrorSyncWindow: Codable, Equatable, Sendable {
    public let startedAt: Date
    public let preparedAt: Date

    private enum CodingKeys: String, CodingKey {
        case startedAt
        case preparedAt = "completedAt"
    }

    public init(startedAt: Date, preparedAt: Date) {
        self.startedAt = startedAt
        self.preparedAt = preparedAt
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

    private enum CodingKeys: String, CodingKey {
        case observation
        case revisions
        case evidence
        case mode
        case window
        case delta
        case coverage
        case outcome
    }

    public init(
        observation: ObservationID,
        revisions: MirrorSyncRevisions,
        evidence: MirrorSyncEvidence,
        mode: MirrorSyncMode,
        window: MirrorSyncWindow,
        delta: MirrorSyncCounts,
        coverage: MirrorSyncCoverage
    ) throws {
        guard window.preparedAt >= window.startedAt else {
            throw MirrorSyncRecordValidationError.reversedWindow
        }
        let deltaCounts = [delta.new, delta.modified, delta.identityChanged, delta.refreshed, delta.removed]
        guard deltaCounts.allSatisfy({ $0 >= 0 }) else {
            throw MirrorSyncRecordValidationError.negativeDeltaCount
        }
        guard coverage.identityRequestedCount >= 0,
              coverage.identityObservedCount >= 0,
              coverage.metadataRequestedCount >= 0,
              coverage.metadataObservedCount >= 0,
              coverage.identityObservedCount <= coverage.identityRequestedCount,
              coverage.metadataObservedCount <= coverage.metadataRequestedCount
        else {
            throw MirrorSyncRecordValidationError.invalidCoverageCount
        }
        guard !coverage.isIdentityComplete
            || coverage.identityObservedCount == coverage.identityRequestedCount,
            !coverage.isMetadataComplete
            || coverage.metadataObservedCount == coverage.metadataRequestedCount
        else {
            throw MirrorSyncRecordValidationError.inconsistentCompleteness
        }
        self.observation = observation
        self.revisions = revisions
        self.evidence = evidence
        self.mode = mode
        self.window = window
        self.delta = delta
        self.coverage = coverage
        outcome = .committed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(MirrorSyncOutcome.self, forKey: .outcome) == .committed else {
            throw DecodingError.dataCorruptedError(
                forKey: .outcome,
                in: container,
                debugDescription: "Synchronization audit outcome must be committed"
            )
        }
        try self.init(
            observation: container.decode(ObservationID.self, forKey: .observation),
            revisions: container.decode(MirrorSyncRevisions.self, forKey: .revisions),
            evidence: container.decode(MirrorSyncEvidence.self, forKey: .evidence),
            mode: container.decode(MirrorSyncMode.self, forKey: .mode),
            window: container.decode(MirrorSyncWindow.self, forKey: .window),
            delta: container.decode(MirrorSyncCounts.self, forKey: .delta),
            coverage: container.decode(MirrorSyncCoverage.self, forKey: .coverage)
        )
    }
}

enum MirrorSyncRecordValidationError: Error, Equatable, Sendable {
    case reversedWindow
    case negativeDeltaCount
    case invalidCoverageCount
    case inconsistentCompleteness
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
    public let syncRecordLimit: Int?

    public init(
        baseRevision: MirrorRevision,
        observation: ObservationID = ObservationID(),
        inventoryChange: InventoryChange,
        repairs: [TrackMirrorRepair],
        upserts: [Track],
        certificates: CertificateChange,
        syncRecord: MirrorSyncRecord? = nil,
        syncRecordLimit: Int? = nil
    ) {
        self.baseRevision = baseRevision
        self.observation = observation
        self.inventoryChange = inventoryChange
        self.repairs = repairs
        self.upserts = upserts
        self.certificates = certificates
        self.syncRecord = syncRecord
        self.syncRecordLimit = syncRecordLimit
    }
}

/// Stable revision result of a successful mirror commit.
public struct MirrorCommitResult: Equatable, Sendable {
    public let revision: MirrorRevision
    /// Exact post-transaction mirror state returned atomically with the accepted revision.
    public let snapshot: TrackMirrorSnapshot

    public init(revision: MirrorRevision, snapshot: TrackMirrorSnapshot) {
        self.revision = revision
        self.snapshot = snapshot
    }
}
