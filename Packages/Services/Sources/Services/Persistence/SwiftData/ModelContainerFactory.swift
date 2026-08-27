// ModelContainerFactory.swift — Centralized SwiftData container creation
// Phase 5 Audit Fix: H1 — Single shared ModelContainer for all models

import Core
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
        Schema(versionedSchema: StoreSchemaV5.self)
    }

    static func create(schema: Schema, configuration: ModelConfiguration) throws -> ModelContainer {
        if try needsRecoveryBootstrap(configuration) {
            try bootstrapRecoveryStore(configuration)
        }
        try prepareLegacyStore(configuration)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private static let trackRecoveryChecksum = "i2Q0M3v/JLttbprhy5I8T0nCkA5O9AYoi9OSQRGpY2s="

    private static let legacyVersions = [
        StoreSchemaV0.versionIdentifier,
        StoreSchemaV1.versionIdentifier,
        StoreSchemaV2.versionIdentifier,
        StoreSchemaV3.versionIdentifier,
        StoreSchemaV4.versionIdentifier,
    ].map(\.description)

    private static func prepareLegacyStore(_ configuration: ModelConfiguration) throws {
        guard try isLegacyStore(configuration) else { return }

        let schema = Schema(versionedSchema: StoreSchemaV4.self)
        let legacyConfiguration = ModelConfiguration(
            configuration.name,
            schema: schema,
            url: configuration.url,
            allowsSave: configuration.allowsSave,
            cloudKitDatabase: configuration.cloudKitDatabase
        )
        let container = try ModelContainer(for: schema, configurations: [legacyConfiguration])
        try bootstrapMembership(in: container)
    }

    private static func bootstrapMembership(in container: ModelContainer) throws {
        let context = ModelContext(container)
        guard try context.fetchCount(FetchDescriptor<PersistedLibraryMember>()) == 0 else { return }

        let tracks = try context.fetch(FetchDescriptor<StoreSchemaV2.PersistedTrack>())
        let canonicalTracks = tracks.filter { track in
            track.appleScriptID == track.trackID && MusicDatabaseTrackID(rawValue: track.trackID) != nil
        }
        guard !canonicalTracks.isEmpty else { return }

        let revision = try context.fetch(FetchDescriptor<StoreSchemaV2.PersistedMirrorState>())
            .first?
            .revisionValue ?? MirrorRevision.initial.value
        try context.transaction {
            for track in canonicalTracks {
                context.insert(PersistedLibraryMember(
                    databaseID: track.trackID,
                    isPresent: true,
                    firstSeenRevisionValue: revision
                ))
            }
        }
    }

    private static func isLegacyStore(_ configuration: ModelConfiguration) throws -> Bool {
        guard !configuration.isStoredInMemoryOnly else { return false }
        guard FileManager.default.fileExists(atPath: configuration.url.path) else { return false }
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType,
            at: configuration.url
        )
        guard let storedVersions = metadata[NSStoreModelVersionIdentifiersKey] as? [String] else { return false }
        return storedVersions.contains { legacyVersions.contains($0) }
    }

    private static func bootstrapRecoveryStore(_ configuration: ModelConfiguration) throws {
        let schema = Schema(versionedSchema: StoreSchemaV2.self)
        let bootstrapConfiguration = ModelConfiguration(
            configuration.name,
            schema: schema,
            url: configuration.url,
            allowsSave: configuration.allowsSave,
            cloudKitDatabase: configuration.cloudKitDatabase
        )
        _ = try ModelContainer(for: schema, configurations: [bootstrapConfiguration])
    }

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
