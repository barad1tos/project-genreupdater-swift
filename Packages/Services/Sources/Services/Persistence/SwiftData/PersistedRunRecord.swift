import Foundation
import SwiftData

@Model
public final class PersistedRunRecord {
    @Attribute(.unique) public var runID: UUID
    public var requestID: UUID
    public var triggerRaw: String
    public var intentRaw: String
    /// Write-only denormalization for future store-level queries; reads derive state from transitions (see
    /// RunRecord.state).
    public var stateRaw: String
    public var scopeData: Data
    public var transitionsData: Data
    public var syncNewCount: Int?
    public var syncModifiedCount: Int?
    public var syncIdentityChangedCount: Int?
    public var syncRefreshedCount: Int?
    public var syncRemovedCount: Int?
    public var failureMessage: String?
    public var startedAt: Date
    public var finishedAt: Date?

    public init(
        runID: UUID,
        requestID: UUID,
        triggerRaw: String,
        intentRaw: String,
        stateRaw: String,
        scopeData: Data,
        transitionsData: Data,
        syncNewCount: Int?,
        syncModifiedCount: Int?,
        syncIdentityChangedCount: Int?,
        syncRefreshedCount: Int?,
        syncRemovedCount: Int?,
        failureMessage: String?,
        startedAt: Date,
        finishedAt: Date?
    ) {
        self.runID = runID
        self.requestID = requestID
        self.triggerRaw = triggerRaw
        self.intentRaw = intentRaw
        self.stateRaw = stateRaw
        self.scopeData = scopeData
        self.transitionsData = transitionsData
        self.syncNewCount = syncNewCount
        self.syncModifiedCount = syncModifiedCount
        self.syncIdentityChangedCount = syncIdentityChangedCount
        self.syncRefreshedCount = syncRefreshedCount
        self.syncRemovedCount = syncRemovedCount
        self.failureMessage = failureMessage
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}
