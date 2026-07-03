// ModelContainerFactory.swift — Centralized SwiftData container creation
// Phase 5 Audit Fix: H1 — Single shared ModelContainer for all models

import Foundation
import SwiftData

/// Creates a shared `ModelContainer` with all SwiftData models.
///
/// Consolidates container creation so that `PersistedTrack` and
/// `PersistedChangeLogEntry` share one container and can maintain
/// relationships.
public enum ModelContainerFactory {
    /// Create a production container persisted to disk.
    public static func create() throws -> ModelContainer {
        let schema = Schema([
            PersistedTrack.self,
            PersistedChangeLogEntry.self,
            PersistedMetricsSnapshot.self,
            PersistedPendingAlbumEntry.self,
            PersistedPendingVerificationMetadata.self,
            PersistedRunRecord.self
        ])
        let config = ModelConfiguration(
            "GenreUpdater",
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// Create an in-memory container (for testing).
    public static func createInMemory() throws -> ModelContainer {
        let schema = Schema([
            PersistedTrack.self,
            PersistedChangeLogEntry.self,
            PersistedMetricsSnapshot.self,
            PersistedPendingAlbumEntry.self,
            PersistedPendingVerificationMetadata.self,
            PersistedRunRecord.self
        ])
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: [config])
    }
}
