import Core
import Foundation
import SwiftData

@Model
final class PersistedMirrorState {
    @Attribute(.unique)
    var key: String

    var scopeData: Data?

    init(key: String = PersistedMirrorState.primaryKey, scopeData: Data? = nil) {
        self.key = key
        self.scopeData = scopeData
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

    static let primaryKey = "track-mirror"
}
