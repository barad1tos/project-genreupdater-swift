import Foundation
import SwiftData

@Model
final class PersistedMirrorState {
    @Attribute(.unique)
    var key: String

    var isSeeded: Bool

    init(key: String = PersistedMirrorState.primaryKey, isSeeded: Bool) {
        self.key = key
        self.isSeeded = isSeeded
    }

    static let primaryKey = "track-mirror"
}
