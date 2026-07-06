import Foundation
import SwiftData

@Model
public final class PersistedFixPlan {
    #Unique<PersistedFixPlan>([\.planID, \.revision])

    public var planID: UUID
    public var revision: Int
    public var sourceRunID: UUID
    public var createdAt: Date
    public var configSnapshotData: Data
    public var scopeSnapshotData: Data
    public var itemsData: Data
    /// Denormalized columns for future queries; reads reconstruct from the blobs.
    public var itemCount: Int
    public var scopeSource: String
    public var configFingerprint: String

    public init(
        planID: UUID,
        revision: Int,
        sourceRunID: UUID,
        createdAt: Date,
        configSnapshotData: Data,
        scopeSnapshotData: Data,
        itemsData: Data,
        itemCount: Int,
        scopeSource: String,
        configFingerprint: String
    ) {
        self.planID = planID
        self.revision = revision
        self.sourceRunID = sourceRunID
        self.createdAt = createdAt
        self.configSnapshotData = configSnapshotData
        self.scopeSnapshotData = scopeSnapshotData
        self.itemsData = itemsData
        self.itemCount = itemCount
        self.scopeSource = scopeSource
        self.configFingerprint = configFingerprint
    }
}
