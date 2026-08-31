import Core
import CoreData
import Foundation
@preconcurrency import SwiftData
import Testing
@testable import Services

@Suite("Physical catalog schema migration")
struct CatalogSchemaMigrationTests {
    private static let deployedV8Checksum = "IuXWWtvT3iB6ovt/1vETsdbNsHGdY0DKQ96oLGb/pY0="
    private static let catalogSchemaChecksum = "5I3LurgXutd9oso6ULjebpBfPQO2RkiE+Atustn9hjM="

    @Test("Current catalog schema remains reopenable without a version change")
    func pinsCatalogSchema() throws {
        try withTemporaryStore { storeURL in
            _ = try migratedContainer(at: storeURL)
            let checksum = try storeChecksum(at: storeURL)
            #expect(checksum == Self.catalogSchemaChecksum, "Unexpected current schema checksum: \(checksum ?? "nil")")
            let reopened = try migratedContainer(at: storeURL)
            let context = ModelContext(reopened)
            #expect(reopened.migrationPlan == nil)
            #expect(try context.fetch(FetchDescriptor<PersistedLibraryMember>()).isEmpty)
            #expect(try context.fetch(FetchDescriptor<PersistedScopeCertificate>()).isEmpty)
            #expect(try context.fetch(FetchDescriptor<PersistedSyncRecord>()).isEmpty)
            #expect(try context.fetch(FetchDescriptor<PersistedMirrorEffect>()).isEmpty)
            #expect(try context.fetch(FetchDescriptor<PersistedCatalogState>()).isEmpty)
            #expect(try context.fetch(FetchDescriptor<PersistedCatalogTrack>()).isEmpty)
            #expect(try context.fetch(FetchDescriptor<PersistedContentRevision>()).isEmpty)
        }
    }

    @Test("V8 stores migrate to V10 without losing pending effects")
    func migratesV8WithNoInferredCatalog() throws {
        try withTemporaryStore { storeURL in
            let legacySchema = Schema(versionedSchema: StoreSchemaV8.self)
            let legacyConfiguration = ModelConfiguration(
                "GenreUpdater",
                schema: legacySchema,
                url: storeURL,
                cloudKitDatabase: .none
            )
            let effectID = UUID()
            do {
                let container = try ModelContainer(for: legacySchema, configurations: [legacyConfiguration])
                let context = ModelContext(container)
                context.insert(PersistedMirrorState(revisionValue: 12))
                context.insert(PersistedMirrorEffect(
                    effectID: effectID,
                    revision: MirrorRevision(value: 12),
                    sequence: 0,
                    effect: .invalidateSnapshot
                ))
                try context.save()
            }
            #expect(try storeChecksum(at: storeURL) == Self.deployedV8Checksum)

            let migrated = try migratedContainer(at: storeURL)
            let context = ModelContext(migrated)
            #expect(migrated.migrationPlan != nil)
            #expect(try context.fetch(FetchDescriptor<PersistedMirrorState>()).first?.revisionValue == 12)
            #expect(try context.fetch(FetchDescriptor<PersistedMirrorEffect>()).map(\.effectID) == [effectID])
            #expect(try context.fetch(FetchDescriptor<PersistedCatalogState>()).isEmpty)
            #expect(try context.fetch(FetchDescriptor<PersistedCatalogTrack>()).isEmpty)
            #expect(try context.fetch(FetchDescriptor<PersistedContentRevision>()).isEmpty)
        }
    }

    @Test("V9 stores migrate with a conservative mirror content baseline")
    func migratesV9ContentRevision() async throws {
        try await withTemporaryStore { storeURL in
            let legacySchema = Schema(versionedSchema: StoreSchemaV9.self)
            let legacyConfiguration = ModelConfiguration(
                "GenreUpdater",
                schema: legacySchema,
                url: storeURL,
                cloudKitDatabase: .none
            )
            do {
                let container = try ModelContainer(for: legacySchema, configurations: [legacyConfiguration])
                let context = ModelContext(container)
                context.insert(PersistedMirrorState(revisionValue: 12))
                try context.save()
            }

            let migrated = try migratedContainer(at: storeURL)
            let store = TrackDataStore(modelContainer: migrated)
            try await store.initialize()

            let snapshot = try await store.loadMirrorSnapshot()
            #expect(snapshot.revision == MirrorRevision(value: 12))
            #expect(snapshot.contentRevision == MirrorRevision(value: 12))
        }
    }

    private func withTemporaryStore(_ operation: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try operation(directory.appending(path: "GenreUpdater.store"))
    }

    private func withTemporaryStore(_ operation: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await operation(directory.appending(path: "GenreUpdater.store"))
    }

    private func migratedContainer(at storeURL: URL) throws -> ModelContainer {
        let schema = ModelContainerFactory.makeSchema()
        let configuration = ModelConfiguration(
            "GenreUpdater",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        return try ModelContainerFactory.create(schema: schema, configuration: configuration)
    }

    private func storeChecksum(at storeURL: URL) throws -> String? {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType,
            at: storeURL
        )
        return metadata[NSPersistentStoreModelVersionChecksumKey] as? String
    }
}
