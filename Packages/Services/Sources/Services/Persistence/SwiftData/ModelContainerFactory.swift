// ModelContainerFactory.swift — Centralized SwiftData container creation
// Phase 5 Audit Fix: H1 — Single shared ModelContainer for all models

import CoreData
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
        let schema = makeSchema()
        let config = ModelConfiguration(
            "GenreUpdater",
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        return try create(schema: schema, configuration: config)
    }

    /// Create an in-memory container (for testing).
    public static func createInMemory() throws -> ModelContainer {
        let schema = makeSchema()
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try create(schema: schema, configuration: config)
    }

    static func makeSchema() -> Schema {
        Schema(versionedSchema: StoreSchemaV4.self)
    }

    static func create(schema: Schema, configuration: ModelConfiguration) throws -> ModelContainer {
        if try needsRecoveryBootstrap(configuration) {
            return try ModelContainer(for: schema, configurations: [configuration])
        }
        return try ModelContainer(
            for: schema,
            migrationPlan: StoreMigrationPlan.self,
            configurations: [configuration]
        )
    }

    private static let trackRecoveryChecksum = "i2Q0M3v/JLttbprhy5I8T0nCkA5O9AYoi9OSQRGpY2s="

    private static func needsRecoveryBootstrap(_ configuration: ModelConfiguration) throws -> Bool {
        guard !configuration.isStoredInMemoryOnly else { return false }
        guard FileManager.default.fileExists(atPath: configuration.url.path) else { return false }
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType,
            at: configuration.url
        )
        return metadata[NSPersistentStoreModelVersionChecksumKey] as? String == trackRecoveryChecksum
    }
}
