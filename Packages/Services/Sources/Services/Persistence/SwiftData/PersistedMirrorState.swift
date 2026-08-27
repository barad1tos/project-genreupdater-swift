import Core
import Foundation
import SwiftData

extension StoreSchemaV2 {
    @Model
    final class PersistedMirrorState {
        @Attribute(.unique)
        var key: String

        var scopeData: Data?
        var revisionValue: UInt64 = MirrorRevision.initial.value

        init(
            key: String = PersistedMirrorState.primaryKey,
            scopeData: Data? = nil,
            revisionValue: UInt64 = MirrorRevision.initial.value
        ) {
            self.key = key
            self.scopeData = scopeData
            self.revisionValue = revisionValue
        }

        static let primaryKey = "track-mirror"
    }
}

extension StoreSchemaV5 {
    @Model
    final class PersistedMirrorState {
        @Attribute(.unique)
        var key: String

        var revisionValue: UInt64 = MirrorRevision.initial.value

        init(
            key: String = PersistedMirrorState.primaryKey,
            revisionValue: UInt64 = MirrorRevision.initial.value
        ) {
            self.key = key
            self.revisionValue = revisionValue
        }

        var revision: MirrorRevision {
            MirrorRevision(value: revisionValue)
        }

        func advanceRevision() throws -> MirrorRevision {
            let nextRevision = try revision.advanced()
            revisionValue = nextRevision.value
            return nextRevision
        }

        static let primaryKey = "track-mirror"
    }
}

typealias PersistedMirrorState = StoreSchemaV5.PersistedMirrorState
