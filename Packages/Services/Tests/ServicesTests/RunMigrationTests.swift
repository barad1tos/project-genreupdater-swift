import Foundation
import SwiftData
import Testing
@testable import Services

@Suite("Run store migrations")
struct RunMigrationTests {
    @Test("A legacy track and undo history survive upgrade, undo, and relaunch")
    func upgradePreservesUndo() async throws {
        let storeURL = try makeStoreDirectory().appendingPathComponent("GenreUpdater.store")
        defer { removeStoreDirectory(storeURL) }
        try copyLegacyStore(to: storeURL)

        do {
            let currentContainer = try openProductionContainer(at: storeURL)
            let trackStore = TrackDataStore(modelContainer: currentContainer)
            let changeLogStore = ChangeLogDataStore(modelContainer: currentContainer)
            let migratedTrack = try #require(try await trackStore.getHistoricalTrack(byID: "T1"))
            #expect(migratedTrack.artist == "Florence & the Machine")
            #expect(migratedTrack.originalArtist == nil)
            #expect(migratedTrack.originalAlbum == nil)
            #expect(migratedTrack.yearBeforeMGU == nil)
            #expect(migratedTrack.yearSetByMGU == nil)

            let bridge = MusicAppTestAccess()
            let secondTrack = try #require(try await trackStore.getHistoricalTrack(byID: "T2"))
            await bridge.setMutationTracks([migratedTrack, secondTrack])
            let coordinator = UndoCoordinator(
                musicApp: bridge,
                idMapper: CanonicalUndoMapper(),
                stores: .init(changeLog: changeLogStore, tracks: trackStore),
                directory: storeURL.deletingLastPathComponent().appendingPathComponent("undo")
            )
            await coordinator.initialize()
            let history = await coordinator.getHistory()
            #expect(history.count == 4)

            try await coordinator.revertBatch(history)
        }

        let relaunchedContainer = try openProductionContainer(at: storeURL)
        let relaunchedTrackStore = TrackDataStore(modelContainer: relaunchedContainer)
        let relaunchedLogStore = ChangeLogDataStore(modelContainer: relaunchedContainer)
        let restoredTrack = try #require(try await relaunchedTrackStore.getHistoricalTrack(byID: "T1"))
        #expect(restoredTrack.artist == "Florence and the Machine")
        #expect(restoredTrack.originalArtist == "Florence and the Machine")
        let restoredYearTrack = try #require(try await relaunchedTrackStore.getHistoricalTrack(byID: "T2"))
        #expect(restoredYearTrack.year == 1998)
        #expect(restoredYearTrack.yearBeforeMGU == 1998)
        #expect(restoredYearTrack.yearSetByMGU == 1998)
        #expect(try await relaunchedLogStore.loadAll().isEmpty)
    }

    @Test("Selective legacy year undo keeps the oldest origin across relaunch")
    func selectiveYearUndo() async throws {
        let storeURL = try makeStoreDirectory().appendingPathComponent("GenreUpdater.store")
        defer { removeStoreDirectory(storeURL) }
        try copyLegacyStore(to: storeURL)

        do {
            let currentContainer = try openProductionContainer(at: storeURL)
            let trackStore = TrackDataStore(modelContainer: currentContainer)
            let changeLogStore = ChangeLogDataStore(modelContainer: currentContainer)
            let bridge = MusicAppTestAccess()
            let firstTrack = try #require(try await trackStore.getHistoricalTrack(byID: "T1"))
            let secondTrack = try #require(try await trackStore.getHistoricalTrack(byID: "T2"))
            await bridge.setMutationTracks([firstTrack, secondTrack])
            let coordinator = UndoCoordinator(
                musicApp: bridge,
                idMapper: CanonicalUndoMapper(),
                stores: .init(changeLog: changeLogStore, tracks: trackStore),
                directory: storeURL.deletingLastPathComponent().appendingPathComponent("undo")
            )
            await coordinator.initialize()
            let yearRevert = try #require(await coordinator.getHistory().first {
                $0.trackID == "T2" && $0.changeType == .yearRevert
            })

            try await coordinator.revertSelective([yearRevert])
        }

        let relaunchedContainer = try openProductionContainer(at: storeURL)
        let trackStore = TrackDataStore(modelContainer: relaunchedContainer)
        let changeLogStore = ChangeLogDataStore(modelContainer: relaunchedContainer)
        let restoredTrack = try #require(try await trackStore.getHistoricalTrack(byID: "T2"))
        #expect(restoredTrack.year == 2019)
        #expect(restoredTrack.yearBeforeMGU == 1998)
        #expect(restoredTrack.yearSetByMGU == 2019)
        let remainingHistory = try await changeLogStore.loadAll()
        #expect(remainingHistory.count == 3)
        #expect(remainingHistory.contains { $0.trackID == "T2" && $0.changeType == .yearUpdate })
    }

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

    private func copyLegacyStore(to storeURL: URL) throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LegacyFixtures/TrackRecoveryLegacy.fixture")
        try FileManager.default.copyItem(at: fixtureURL, to: storeURL)
    }

    private func openProductionContainer(at storeURL: URL) throws -> ModelContainer {
        let schema = ModelContainerFactory.makeSchema()
        let configuration = ModelConfiguration(
            "GenreUpdaterTrackMigration",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        return try ModelContainerFactory.create(schema: schema, configuration: configuration)
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
