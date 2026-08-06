import Foundation
import SwiftData
import Testing
@testable import Services

@Suite("Run store migrations")
struct RunMigrationTests {
    @Test("Adding work-item storage preserves existing run records")
    func migratesWorkItemModel() throws {
        let storeURL = try makeStoreDirectory().appendingPathComponent("GenreUpdater.store")
        defer { removeStoreDirectory(storeURL) }
        let runID = UUID()

        do {
            let legacySchema = runSchema(includesItems: false)
            let legacyConfig = ModelConfiguration(
                "GenreUpdaterMigration",
                schema: legacySchema,
                url: storeURL,
                cloudKitDatabase: .none
            )
            let legacyContainer = try ModelContainer(for: legacySchema, configurations: [legacyConfig])
            try insertRunRow(runID: runID, transitionsData: validRunTransitionsData(), into: legacyContainer)
        }

        let currentSchema = runSchema(includesItems: true)
        let currentConfig = ModelConfiguration(
            "GenreUpdaterMigration",
            schema: currentSchema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let currentContainer = try ModelContainer(for: currentSchema, configurations: [currentConfig])
        let context = ModelContext(currentContainer)
        #expect(try context.fetch(FetchDescriptor<PersistedRunRecord>()).map(\.runID) == [runID])

        let item = makeWorkItem(state: .prepared)
        try context.insert(PersistedRunWorkItem(
            runID: runID,
            itemID: item.id,
            position: 0,
            itemData: JSONEncoder().encode(item)
        ))
        try context.save()
        #expect(try context.fetch(FetchDescriptor<PersistedRunWorkItem>()).count == 1)
    }

    @Test("Adding report-item storage preserves existing run records")
    func migratesReportItemModel() throws {
        let storeURL = try makeStoreDirectory().appendingPathComponent("GenreUpdater.store")
        defer { removeStoreDirectory(storeURL) }
        let runID = UUID()

        do {
            let legacySchema = runSchema(includesItems: true)
            let legacyConfig = ModelConfiguration(
                "GenreUpdaterReportMigration",
                schema: legacySchema,
                url: storeURL,
                cloudKitDatabase: .none
            )
            let legacyContainer = try ModelContainer(for: legacySchema, configurations: [legacyConfig])
            try insertRunRow(runID: runID, transitionsData: validRunTransitionsData(), into: legacyContainer)
        }

        let currentSchema = runSchema(includesItems: true, includesReportItems: true)
        let currentConfig = ModelConfiguration(
            "GenreUpdaterReportMigration",
            schema: currentSchema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let currentContainer = try ModelContainer(for: currentSchema, configurations: [currentConfig])
        let context = ModelContext(currentContainer)
        #expect(try context.fetch(FetchDescriptor<PersistedRunRecord>()).map(\.runID) == [runID])

        let item = makeWorkItem(state: .outcome(.written))
        try context.insert(PersistedRunReportItem(
            runID: runID,
            position: 0,
            runStartedAt: Date(timeIntervalSince1970: 100),
            item: item,
            itemData: JSONEncoder().encode(item)
        ))
        try context.save()
        #expect(try context.fetch(FetchDescriptor<PersistedRunReportItem>()).count == 1)
    }

    private func makeStoreDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func removeStoreDirectory(_ storeURL: URL) {
        do {
            try FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
        } catch {
            Issue.record("Failed to remove migration fixture: \(error)")
        }
    }
}

private func runSchema(includesItems: Bool, includesReportItems: Bool = false) -> Schema {
    var models: [any PersistentModel.Type] = [
        PersistedTrack.self,
        PersistedChangeLogEntry.self,
        PersistedMetricsSnapshot.self,
        PersistedPendingAlbumEntry.self,
        PersistedPendingVerificationMetadata.self,
        PersistedRunRecord.self,
        PersistedFixPlan.self,
        PersistedFixPlanDecision.self,
    ]
    if includesItems {
        models.append(PersistedRunWorkItem.self)
    }
    if includesReportItems {
        models.append(PersistedRunReportItem.self)
    }
    return Schema(models)
}
