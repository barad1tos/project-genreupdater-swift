import Core
import Foundation
import SwiftData

extension StoreSchemaV8 {
    @Model
    final class PersistedMirrorEffect {
        @Attribute(.unique)
        var effectID: UUID

        var revisionValue: UInt64
        var sequence: Int
        var kindRaw: String
        var artist: String?
        var album: String?
        var completedAt: Date?

        init(
            effectID: UUID = UUID(),
            revision: MirrorRevision,
            sequence: Int,
            effect: MirrorEffect
        ) {
            self.effectID = effectID
            revisionValue = revision.value
            self.sequence = sequence
            switch effect {
            case let .invalidateAlbumYear(identity):
                kindRaw = Kind.albumYear.rawValue
                artist = identity.artist
                album = identity.album
            case let .invalidateAPIResults(identity):
                kindRaw = Kind.apiResults.rawValue
                artist = identity.artist
                album = identity.album
            case .invalidateSnapshot:
                kindRaw = Kind.snapshot.rawValue
            case .refreshProjections:
                kindRaw = Kind.projections.rawValue
            }
        }

        func pendingEffect() throws -> PendingMirrorEffect {
            let effect: MirrorEffect
            switch Kind(rawValue: kindRaw) {
            case .albumYear:
                effect = try .invalidateAlbumYear(albumIdentity())
            case .apiResults:
                effect = try .invalidateAPIResults(albumIdentity())
            case .snapshot:
                effect = .invalidateSnapshot
            case .projections:
                effect = .refreshProjections
            case nil:
                throw MirrorEffectPersistenceError.invalidKind(kindRaw)
            }
            return PendingMirrorEffect(
                id: effectID,
                revision: MirrorRevision(value: revisionValue),
                sequence: sequence,
                effect: effect
            )
        }

        private func albumIdentity() throws -> AlbumIdentity {
            guard let artist, let album else {
                throw MirrorEffectPersistenceError.missingAlbumIdentity(effectID)
            }
            let identity = AlbumIdentity(artist: artist, album: album)
            guard identity.isComplete else {
                throw MirrorEffectPersistenceError.missingAlbumIdentity(effectID)
            }
            return identity
        }

        private enum Kind: String {
            case albumYear
            case apiResults
            case snapshot
            case projections
        }
    }
}

typealias PersistedMirrorEffect = StoreSchemaV8.PersistedMirrorEffect

enum MirrorEffectPersistenceError: LocalizedError {
    case invalidKind(String)
    case missingAlbumIdentity(UUID)
    case missingEffect(UUID)

    var errorDescription: String? {
        switch self {
        case let .invalidKind(kind):
            "Persisted mirror effect has invalid kind \(kind)"
        case let .missingAlbumIdentity(id):
            "Persisted mirror effect \(id) has no complete album identity"
        case let .missingEffect(id):
            "Persisted mirror effect \(id) is missing"
        }
    }
}

extension TrackDataStore {
    func enqueueMirrorEffects(_ effects: [MirrorEffect], revision: MirrorRevision) -> [UUID] {
        effects.enumerated().map { sequence, effect in
            let persisted = PersistedMirrorEffect(revision: revision, sequence: sequence, effect: effect)
            modelContext.insert(persisted)
            return persisted.effectID
        }
    }

    public func pendingMirrorEffects() async throws -> [PendingMirrorEffect] {
        let descriptor = FetchDescriptor<PersistedMirrorEffect>(
            predicate: #Predicate { $0.completedAt == nil },
            sortBy: [
                SortDescriptor(\.revisionValue),
                SortDescriptor(\.sequence),
            ]
        )
        return try modelContext.fetch(descriptor).map { try $0.pendingEffect() }
    }

    public func nextPendingMirrorEffect() async throws -> PendingMirrorEffect? {
        var descriptor = FetchDescriptor<PersistedMirrorEffect>(
            predicate: #Predicate { $0.completedAt == nil },
            sortBy: [
                SortDescriptor(\.revisionValue),
                SortDescriptor(\.sequence),
            ]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.map { try $0.pendingEffect() }
    }

    public func completeMirrorEffect(id: UUID) async throws {
        let descriptor = FetchDescriptor<PersistedMirrorEffect>(
            predicate: #Predicate { $0.effectID == id }
        )
        guard let effect = try modelContext.fetch(descriptor).first else {
            throw MirrorEffectPersistenceError.missingEffect(id)
        }
        guard effect.completedAt == nil else { return }
        effect.completedAt = Date()
        try modelContext.save()
    }
}
