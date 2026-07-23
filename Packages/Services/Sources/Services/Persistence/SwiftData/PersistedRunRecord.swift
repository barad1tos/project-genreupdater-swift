import Foundation
import SwiftData

@Model
public final class PersistedRunRecord {
    @Attribute(.unique) public var runID: UUID
    public var requestID: UUID
    public var triggerRaw: String
    public var intentRaw: String
    /// Denormalized state column used by report-query predicates; reads still
    /// derive the canonical state from transitions (see RunRecord.state).
    public var stateRaw: String
    /// Denormalized write gate used by checkpoints so they do not decode the full run payload.
    public var writeAuthorityRaw: String?
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

    init(record: RunRecord, scopeData: Data, payloadData: Data) {
        runID = record.runID.rawValue
        requestID = record.requestID.rawValue
        triggerRaw = record.trigger.rawValue
        intentRaw = record.intent.rawValue
        stateRaw = record.state.rawValue
        writeAuthorityRaw = record.configuration?.writeAuthority.rawValue
        self.scopeData = scopeData
        transitionsData = payloadData
        syncNewCount = record.syncSummary?.new
        syncModifiedCount = record.syncSummary?.modified
        syncIdentityChangedCount = record.syncSummary?.identityChanged
        syncRefreshedCount = record.syncSummary?.refreshed
        syncRemovedCount = record.syncSummary?.removed
        failureMessage = record.failureMessage
        startedAt = record.startedAt
        finishedAt = record.finishedAt
    }

    public init(
        runID: UUID,
        intentRaw: String,
        stateRaw: String,
        scopeData: Data,
        transitionsData: Data,
        startedAt: Date,
        finishedAt: Date?
    ) {
        self.runID = runID
        requestID = UUID()
        triggerRaw = RunTrigger.manualCheck.rawValue
        self.intentRaw = intentRaw
        self.stateRaw = stateRaw
        writeAuthorityRaw = nil
        self.scopeData = scopeData
        self.transitionsData = transitionsData
        syncNewCount = nil
        syncModifiedCount = nil
        syncIdentityChangedCount = nil
        syncRefreshedCount = nil
        syncRemovedCount = nil
        failureMessage = nil
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}
