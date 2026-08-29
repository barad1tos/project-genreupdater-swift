import Core
import Foundation
import SwiftData

extension StoreSchemaV7 {
    @Model
    final class PersistedSyncRecord {
        @Attribute(.unique)
        var observationID: UUID

        var baseRevisionValue: UInt64
        var committedRevisionValue: UInt64
        var membershipFingerprint: String
        var scopeID: UUID
        var certificateID: UUID?
        var modeRaw: String
        var startedAt: Date
        var completedAt: Date
        var newCount: Int
        var modifiedCount: Int
        var identityChangedCount: Int
        var refreshedCount: Int
        var removedCount: Int
        var identityRequestedCount: Int
        var identityObservedCount: Int
        var metadataRequestedCount: Int
        var metadataObservedCount: Int
        var isMembershipComplete: Bool
        var isIdentityComplete: Bool
        var isMetadataComplete: Bool
        var outcomeRaw: String

        init(record: MirrorSyncRecord) {
            observationID = record.observation.value
            baseRevisionValue = record.revisions.base.value
            committedRevisionValue = record.revisions.committed.value
            membershipFingerprint = record.evidence.membership.fingerprint
            scopeID = record.evidence.scopeID
            certificateID = record.evidence.certificateID
            modeRaw = record.mode.rawValue
            startedAt = record.window.startedAt
            completedAt = record.window.completedAt
            newCount = record.delta.new
            modifiedCount = record.delta.modified
            identityChangedCount = record.delta.identityChanged
            refreshedCount = record.delta.refreshed
            removedCount = record.delta.removed
            identityRequestedCount = record.coverage.identityRequestedCount
            identityObservedCount = record.coverage.identityObservedCount
            metadataRequestedCount = record.coverage.metadataRequestedCount
            metadataObservedCount = record.coverage.metadataObservedCount
            isMembershipComplete = record.coverage.isMembershipComplete
            isIdentityComplete = record.coverage.isIdentityComplete
            isMetadataComplete = record.coverage.isMetadataComplete
            outcomeRaw = record.outcome.rawValue
        }
    }
}

typealias PersistedSyncRecord = StoreSchemaV7.PersistedSyncRecord
