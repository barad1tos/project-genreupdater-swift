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

        var revision: MirrorRevision {
            MirrorRevision(value: revisionValue)
        }

        func coverage() throws -> MirrorCoverage {
            guard let scopeData else { return .unknown }
            return try .verified(JSONDecoder().decode(MirrorScope.self, from: scopeData))
        }

        func apply(_ change: MirrorCoverageChange) throws {
            switch try coverage().applying(change) {
            case let .verified(scope):
                scopeData = try JSONEncoder().encode(scope)
            case .unknown:
                scopeData = nil
            }
        }

        func advanceRevision() -> MirrorRevision {
            let nextRevision = revision.advanced()
            revisionValue = nextRevision.value
            return nextRevision
        }

        static let primaryKey = "track-mirror"
    }
}

typealias PersistedMirrorState = StoreSchemaV2.PersistedMirrorState
