// Phase 2A: Persistence Layer

import Core
import Foundation
import OSLog
import SwiftData

/// Persistent store for track processing state using SwiftData.
///
/// Uses `@ModelActor` for background-safe ModelContext access.
/// Designed for libraries with 30K+ tracks — batch operations use
/// chunked inserts to avoid memory pressure.
@ModelActor
public actor TrackDataStore: TrackStateStore {
    private let log = AppLogger.make(category: "trackstore")

    /// Chunk size for batch insert operations.
    private static let batchChunkSize = 500

    // MARK: - Initialization

    public func initialize() async throws {
        log.info("SwiftData track store initialized")
    }

    // MARK: - Read Operations

    public func loadAllTracks() async throws -> [Track] {
        let descriptor = FetchDescriptor<PersistedTrack>(
            sortBy: [SortDescriptor(\.name)]
        )
        let persisted = try modelContext.fetch(descriptor)
        return persisted.map { $0.toTrack() }
    }

    public func getTrack(byID id: String) async throws -> Track? {
        let descriptor = FetchDescriptor<PersistedTrack>(
            predicate: #Predicate { $0.trackID == id }
        )
        return try modelContext.fetch(descriptor).first?.toTrack()
    }

    public func getUnprocessedTracks() async throws -> [Track] {
        let descriptor = FetchDescriptor<PersistedTrack>(
            predicate: #Predicate {
                $0.genreUpdated == false || $0.yearUpdated == false
            }
        )
        let persisted = try modelContext.fetch(descriptor)
        return persisted.map { $0.toTrack() }
    }

    public func trackCount() async throws -> Int {
        let descriptor = FetchDescriptor<PersistedTrack>()
        return try modelContext.fetchCount(descriptor)
    }

    // MARK: - Write Operations

    public func saveTracks(_ tracks: [Track]) async throws {
        let chunks = tracks.chunked(into: Self.batchChunkSize)

        for chunk in chunks {
            for track in chunk {
                let descriptor = FetchDescriptor<PersistedTrack>(
                    predicate: #Predicate { $0.trackID == track.id }
                )

                if let existing = try modelContext.fetch(descriptor).first {
                    existing.update(from: track)
                } else {
                    let persisted = PersistedTrack(from: track)
                    modelContext.insert(persisted)
                }
            }

            try modelContext.save()
        }

        log.info("Saved \(tracks.count, privacy: .public) tracks")
    }

    @discardableResult
    public func deleteTrackIDs(_ ids: [String]) async throws -> Int {
        let uniqueIDs = Array(Set(ids)).sorted()
        guard !uniqueIDs.isEmpty else { return 0 }

        var deletedCount = 0
        let chunks = uniqueIDs.chunked(into: Self.batchChunkSize)
        for chunk in chunks {
            for id in chunk {
                let descriptor = FetchDescriptor<PersistedTrack>(
                    predicate: #Predicate { $0.trackID == id }
                )
                let persistedTracks = try modelContext.fetch(descriptor)
                for persistedTrack in persistedTracks {
                    modelContext.delete(persistedTrack)
                    deletedCount += 1
                }
            }

            try modelContext.save()
        }

        log.info("Deleted \(deletedCount, privacy: .public) persisted tracks")
        return deletedCount
    }

    public func persistAppliedChange(_ change: ChangeLogEntry) async throws {
        do {
            let descriptor = FetchDescriptor<PersistedTrack>(
                predicate: #Predicate { $0.trackID == change.trackID }
            )
            guard let persisted = try modelContext.fetch(descriptor).first else {
                throw TrackStoreError.missingTrack(id: change.trackID)
            }

            let updated = try persisted.toTrack().applying(change)
            persisted.update(from: updated)
            switch change.changeType {
            case .genreUpdate:
                persisted.genreUpdated = true
            case .yearUpdate, .yearRevert:
                persisted.yearUpdated = true
            case .trackCleaning, .albumCleaning, .artistRename:
                break
            }
            persisted.processedDate = .now

            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}

// MARK: - Factory

extension TrackDataStore {
    /// Create a track store with the default shared ModelContainer.
    public static func createDefault() throws -> TrackDataStore {
        let container = try ModelContainerFactory.create()
        return TrackDataStore(modelContainer: container)
    }

    /// Create a track store with an in-memory container (for testing).
    public static func createInMemory() throws -> TrackDataStore {
        let container = try ModelContainerFactory.createInMemory()
        return TrackDataStore(modelContainer: container)
    }
}
