// SwiftDataTrackStore.swift — SwiftData-backed track state persistence
// Phase 2A: Persistence Layer

import Foundation
import SwiftData
import Core
import OSLog

/// Persistent store for track processing state using SwiftData.
///
/// Uses `@ModelActor` for background-safe ModelContext access.
/// Designed for libraries with 30K+ tracks — batch operations use
/// chunked inserts to avoid memory pressure.
@ModelActor
public actor SwiftDataTrackStore: TrackStateStore {
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

    public func updateTrackProcessingState(
        id: String,
        genreUpdated: Bool?,
        yearUpdated: Bool?
    ) async throws {
        let descriptor = FetchDescriptor<PersistedTrack>(
            predicate: #Predicate { $0.trackID == id }
        )

        guard let persisted = try modelContext.fetch(descriptor).first else {
            log.warning("Track not found for processing state update: \(id, privacy: .private)")
            return
        }

        if let genreUpdated {
            persisted.genreUpdated = genreUpdated
        }
        if let yearUpdated {
            persisted.yearUpdated = yearUpdated
        }
        persisted.processedDate = .now

        try modelContext.save()
    }
}

// MARK: - Factory

extension SwiftDataTrackStore {
    /// Create a track store with the default SwiftData configuration.
    public static func createDefault() throws -> SwiftDataTrackStore {
        let schema = Schema([PersistedTrack.self])
        let config = ModelConfiguration(
            "GenreUpdater",
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [config])
        return SwiftDataTrackStore(modelContainer: container)
    }

    /// Create a track store with an in-memory container (for testing).
    public static func createInMemory() throws -> SwiftDataTrackStore {
        let schema = Schema([PersistedTrack.self])
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: schema, configurations: [config])
        return SwiftDataTrackStore(modelContainer: container)
    }
}
