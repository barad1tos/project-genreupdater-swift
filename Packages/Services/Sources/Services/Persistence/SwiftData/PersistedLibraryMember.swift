import Core
import Foundation
import SwiftData

extension StoreSchemaV3 {
    @Model
    final class PersistedLibraryMember {
        @Attribute(.unique)
        var databaseID: String

        var isPresent: Bool
        var firstSeenRevisionValue: UInt64
        var lastSeenMembershipFingerprint: String?
        var removalRevisionValue: UInt64?
        var removedAt: Date?

        init(
            databaseID: String,
            isPresent: Bool,
            firstSeenRevisionValue: UInt64,
            lastSeenMembershipFingerprint: String? = nil,
            removalRevisionValue: UInt64? = nil,
            removedAt: Date? = nil
        ) {
            self.databaseID = databaseID
            self.isPresent = isPresent
            self.firstSeenRevisionValue = firstSeenRevisionValue
            self.lastSeenMembershipFingerprint = lastSeenMembershipFingerprint
            self.removalRevisionValue = removalRevisionValue
            self.removedAt = removedAt
        }
    }
}

extension StoreSchemaV4 {
    @Model
    final class PersistedLibraryMember {
        @Attribute(.unique)
        var databaseID: String

        var isPresent: Bool
        var firstSeenRevisionValue: UInt64
        @Attribute(originalName: "lastSeenMembershipFingerprint")
        var lastSeenFingerprint: String?
        var removalRevisionValue: UInt64?
        var removedAt: Date?

        init(
            databaseID: String,
            isPresent: Bool,
            firstSeenRevisionValue: UInt64,
            lastSeenFingerprint: String? = nil,
            removalRevisionValue: UInt64? = nil,
            removedAt: Date? = nil
        ) {
            self.databaseID = databaseID
            self.isPresent = isPresent
            self.firstSeenRevisionValue = firstSeenRevisionValue
            self.lastSeenFingerprint = lastSeenFingerprint
            self.removalRevisionValue = removalRevisionValue
            self.removedAt = removedAt
        }
    }
}

typealias PersistedLibraryMember = StoreSchemaV4.PersistedLibraryMember

extension PersistedLibraryMember {
    func markSeen(stamp: MembershipStamp) {
        guard lastSeenFingerprint != stamp.fingerprint else { return }
        lastSeenFingerprint = stamp.fingerprint
    }

    func markPresent(stamp: MembershipStamp) {
        isPresent = true
        markSeen(stamp: stamp)
        removalRevisionValue = nil
        removedAt = nil
    }

    func markRemoved(revision: MirrorRevision, at date: Date) {
        isPresent = false
        removalRevisionValue = revision.value
        removedAt = date
    }
}
