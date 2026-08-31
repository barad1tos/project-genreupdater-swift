import Core
import Foundation
import SwiftData

extension StoreSchemaV10 {
    @Model
    final class PersistedContentRevision {
        @Attribute(.unique)
        var key: String

        var revisionValue: UInt64

        init(
            key: String = PersistedContentRevision.primaryKey,
            revisionValue: UInt64 = MirrorRevision.initial.value
        ) {
            self.key = key
            self.revisionValue = revisionValue
        }

        var revision: MirrorRevision {
            MirrorRevision(value: revisionValue)
        }

        static let primaryKey = "track-mirror-content"
    }
}

typealias PersistedContentRevision = StoreSchemaV10.PersistedContentRevision

extension TrackDataStore {
    func fetchContentRevision() throws -> PersistedContentRevision? {
        let key = PersistedContentRevision.primaryKey
        let descriptor = FetchDescriptor<PersistedContentRevision>(
            predicate: #Predicate { $0.key == key }
        )
        return try modelContext.fetch(descriptor).first
    }

    func recordContentRevision(
        for effects: [MirrorEffect],
        committedRevision: MirrorRevision,
        baselineRevision: MirrorRevision
    ) throws {
        let state: PersistedContentRevision
        if let storedState = try fetchContentRevision() {
            state = storedState
        } else {
            let newState = PersistedContentRevision(revisionValue: baselineRevision.value)
            modelContext.insert(newState)
            state = newState
        }

        if effects.contains(.refreshProjections) {
            state.revisionValue = committedRevision.value
        }
    }

    func stageMirrorEffects(
        _ effects: [MirrorEffect],
        revision: MirrorRevision,
        baseline: MirrorRevision
    ) throws -> [UUID] {
        try recordContentRevision(
            for: effects,
            committedRevision: revision,
            baselineRevision: baseline
        )
        return try enqueueMirrorEffects(effects, revision: revision)
    }
}
