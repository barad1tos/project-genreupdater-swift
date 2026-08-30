import Foundation
import SwiftData

@ModelActor
public actor CatalogDataStore {
    public func replaceSnapshot(_ snapshot: CatalogSnapshot) async throws {
        try Task.checkCancellation()
        let duplicateIDs = Self.duplicateIDs(in: snapshot.tracks)
        guard duplicateIDs.isEmpty else {
            throw CatalogStoreError.duplicateIDs(duplicateIDs)
        }

        do {
            try modelContext.transaction {
                try modelContext.fetch(FetchDescriptor<PersistedCatalogTrack>()).forEach(modelContext.delete)
                for (position, track) in snapshot.tracks.enumerated() {
                    try modelContext.insert(PersistedCatalogTrack(track: track, position: position))
                }
                if let state = try modelContext.fetch(FetchDescriptor<PersistedCatalogState>()).first {
                    state.fingerprint = snapshot.fingerprint.rawValue
                    state.capturedAt = snapshot.capturedAt
                } else {
                    modelContext.insert(PersistedCatalogState(
                        fingerprint: snapshot.fingerprint.rawValue,
                        capturedAt: snapshot.capturedAt
                    ))
                }
                try modelContext.save()
            }
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    public func loadSnapshot() async throws -> CatalogSnapshot? {
        try Task.checkCancellation()
        guard let state = try modelContext.fetch(FetchDescriptor<PersistedCatalogState>()).first else {
            let rowCount = try modelContext.fetchCount(FetchDescriptor<PersistedCatalogTrack>())
            guard rowCount == 0 else { throw CatalogStoreError.missingSnapshotState }
            return nil
        }
        let descriptor = FetchDescriptor<PersistedCatalogTrack>(sortBy: [SortDescriptor(\.position)])
        let tracks = try modelContext.fetch(descriptor).map { try $0.catalogTrack() }
        let snapshot = CatalogSnapshot(tracks: tracks, capturedAt: state.capturedAt)
        guard snapshot.fingerprint.rawValue == state.fingerprint else {
            throw CatalogStoreError.fingerprintMismatch(
                expected: state.fingerprint,
                actual: snapshot.fingerprint.rawValue
            )
        }
        return snapshot
    }

    private static func duplicateIDs(in tracks: [CatalogTrack]) -> [String] {
        var seen: Set<CatalogTrackID> = []
        var duplicates: Set<CatalogTrackID> = []
        for track in tracks where !seen.insert(track.id).inserted {
            duplicates.insert(track.id)
        }
        return duplicates.map(\.displayValue).sorted()
    }
}

enum CatalogStoreError: LocalizedError, Equatable, Sendable {
    case duplicateIDs([String])
    case fingerprintMismatch(expected: String, actual: String)
    case invalidCatalogID(String)
    case invalidGenres(String)
    case missingSnapshotState

    var errorDescription: String? {
        switch self {
        case let .duplicateIDs(ids):
            "Catalog snapshot contains duplicate IDs: \(ids.joined(separator: ", "))"
        case let .fingerprintMismatch(expected, actual):
            "Catalog snapshot fingerprint mismatch: expected \(expected), got \(actual)"
        case let .invalidCatalogID(id):
            "Persisted catalog row has invalid ID: \(id)"
        case let .invalidGenres(id):
            "Persisted catalog row \(id) has invalid genres"
        case .missingSnapshotState:
            "Persisted catalog rows exist without snapshot state"
        }
    }
}
