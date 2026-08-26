import Core
import CoreData
import Foundation
import SwiftData
import Testing
@testable import Services

@Suite("SwiftData store schema migration")
struct StoreSchemaMigrationTests {
    private static let deployedChecksum = "vrVyyiD+OtvleDs7wa27tSGnDMLj4Bts1NWHukp62k4="
    private static let runID = fixtureID("00000000-0000-0000-0000-000000000001")
    private static let workItemID = fixtureID("00000000-0000-0000-0000-000000000002")
    private static let planID = fixtureID("00000000-0000-0000-0000-000000000003")
    private static let changeID = fixtureID("00000000-0000-0000-0000-000000000004")
    private static let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
    private static let payload = Data("migration-sentinel".utf8)

    @Test("The deployed V1 store migrates every entity and reopens as V2")
    func migratesDeployedStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "GenreUpdater.store")

        try FileManager.default.copyItem(at: Self.fixtureURL, to: storeURL)
        #expect(try storeChecksum(at: storeURL) == Self.deployedChecksum)

        try verifyMigratedStore(migratedContainer(at: storeURL))
        try verifyMigratedStore(migratedContainer(at: storeURL))
    }

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "LegacyFixtures/StoreSchemaV1.fixture")
    }

    private static func fixtureID(_ value: String) -> UUID {
        guard let identifier = UUID(uuidString: value) else {
            preconditionFailure("Invalid synthetic migration fixture UUID")
        }
        return identifier
    }

    private func storeChecksum(at storeURL: URL) throws -> String {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType,
            at: storeURL
        )
        return try #require(metadata[NSPersistentStoreModelVersionChecksumKey] as? String)
    }

    private func migratedContainer(at storeURL: URL) throws -> ModelContainer {
        let schema = ModelContainerFactory.makeSchema()
        let configuration = ModelConfiguration(
            "GenreUpdater",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        return try ModelContainerFactory.create(schema: schema, configuration: configuration)
    }

    private func verifyMigratedStore(_ container: ModelContainer) throws {
        let context = ModelContext(container)
        let tracks = try context.fetch(FetchDescriptor<PersistedTrack>())
        let changes = try context.fetch(FetchDescriptor<PersistedChangeLogEntry>())
        let mirrors = try context.fetch(FetchDescriptor<PersistedMirrorState>())
        let metrics = try context.fetch(FetchDescriptor<PersistedMetricsSnapshot>())
        let pendingAlbums = try context.fetch(FetchDescriptor<PersistedPendingAlbumEntry>())
        let pendingMetadata = try context.fetch(FetchDescriptor<PersistedPendingVerificationMetadata>())
        let runs = try context.fetch(FetchDescriptor<PersistedRunRecord>())
        let workItems = try context.fetch(FetchDescriptor<PersistedRunWorkItem>())
        let reportItems = try context.fetch(FetchDescriptor<PersistedRunReportItem>())
        let plans = try context.fetch(FetchDescriptor<PersistedFixPlan>())
        let decisions = try context.fetch(FetchDescriptor<PersistedFixPlanDecision>())

        #expect(tracks.count == 1)
        #expect(tracks.first?.trackID == "track-sentinel")
        #expect(tracks.first?.changeLog.map(\.entryID) == [Self.changeID])
        #expect(changes.count == 1)
        #expect(changes.first?.track?.trackID == "track-sentinel")
        #expect(mirrors.count == 1)
        let mirror = try #require(mirrors.first)
        #expect(try mirror.scopeData == JSONEncoder().encode(MirrorScope.fullLibrary))
        #expect(try mirror.coverage() == .verified(.fullLibrary))
        #expect(mirror.revisionValue == 0)
        #expect(metrics.first?.totalTracks == 1)
        #expect(pendingAlbums.first?.entryID == "pending-sentinel")
        #expect(pendingMetadata.first?.lastAutoVerification == Self.timestamp)
        #expect(runs.first?.runID == Self.runID)
        #expect(runs.first?.scopeData == Self.payload)
        #expect(workItems.first?.runID == Self.runID)
        #expect(workItems.first?.itemID == Self.workItemID)
        #expect(reportItems.first?.runID == Self.runID)
        #expect(reportItems.first?.itemID == Self.workItemID)
        #expect(plans.first?.planID == Self.planID)
        #expect(plans.first?.sourceRunID == Self.runID)
        #expect(decisions.first?.planID == Self.planID)

        #expect(metrics.count == 1)
        #expect(pendingAlbums.count == 1)
        #expect(pendingMetadata.count == 1)
        #expect(runs.count == 1)
        #expect(workItems.count == 1)
        #expect(reportItems.count == 1)
        #expect(plans.count == 1)
        #expect(decisions.count == 1)
    }
}
