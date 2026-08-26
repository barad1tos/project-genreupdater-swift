import Core
import CoreData
import Foundation
import SwiftData
import Testing
@testable import Services

@Suite("SwiftData store schema migration")
struct StoreSchemaMigrationTests {
    private static let preMirrorChecksum = "4gyxaR3XVbJ4CxMo9jcZdflFXNqaKxs0rO8+kkx/1v0="
    private static let mirrorScopeChecksum = "vrVyyiD+OtvleDs7wa27tSGnDMLj4Bts1NWHukp62k4="
    private static let runID = fixtureID("00000000-0000-0000-0000-000000000001")
    private static let workItemID = fixtureID("00000000-0000-0000-0000-000000000002")
    private static let planID = fixtureID("00000000-0000-0000-0000-000000000003")
    private static let changeID = fixtureID("00000000-0000-0000-0000-000000000004")
    private static let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
    private static let payload = Data("migration-sentinel".utf8)

    @Test("The mirror-scope V1 store migrates every entity and reopens as V2")
    func migratesMirrorScopeStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "GenreUpdater.store")

        try FileManager.default.copyItem(at: Self.fixtureURL, to: storeURL)
        #expect(try storeChecksum(at: storeURL) == Self.mirrorScopeChecksum)

        try verifyMigratedStore(migratedContainer(at: storeURL), hasMirrorState: true)
        try verifyMigratedStore(migratedContainer(at: storeURL), hasMirrorState: true)
    }

    @Test("A pre-mirror store migrates without losing persisted entities")
    func migratesPreMirrorStore() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "GenreUpdater.store")

        try writeV0Store(at: storeURL)
        #expect(try storeChecksum(at: storeURL) == Self.preMirrorChecksum)

        do {
            let container = try migratedContainer(at: storeURL)
            try verifyMigratedStore(container, hasMirrorState: false)
            let snapshot = try await TrackDataStore(modelContainer: container).loadMirrorSnapshot()
            #expect(snapshot.coverage == .unknown)
            #expect(snapshot.revision == .initial)
        }
        do {
            let container = try migratedContainer(at: storeURL)
            try verifyMigratedStore(container, hasMirrorState: false)
        }
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

    private func writeV0Store(at storeURL: URL) throws {
        let models = StoreSchemaV1.models.filter { $0 != StoreSchemaV1.PersistedMirrorState.self }
        let schema = Schema(models, version: Schema.Version(1, 0, 0))
        let configuration = ModelConfiguration(
            "GenreUpdater",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let track = fixtureTrack()
        let change = StoreSchemaV1.PersistedChangeLogEntry(
            entryID: Self.changeID,
            timestamp: Self.timestamp,
            trackID: track.trackID,
            track: track
        )
        track.changeLog = [change]

        context.insert(track)
        context.insert(change)
        context.insert(StoreSchemaV1.PersistedMetricsSnapshot(totalTracks: 1, timestamp: Self.timestamp))
        context.insert(StoreSchemaV1.PersistedPendingAlbumEntry(
            entryID: "pending-sentinel",
            timestamp: Self.timestamp
        ))
        context.insert(StoreSchemaV1.PersistedPendingVerificationMetadata(lastAutoVerification: Self.timestamp))
        context.insert(StoreSchemaV1.PersistedRunRecord(
            runID: Self.runID,
            data: Self.payload,
            timestamp: Self.timestamp
        ))
        context.insert(StoreSchemaV1.PersistedRunWorkItem(
            key: "work-sentinel",
            runID: Self.runID,
            itemID: Self.workItemID,
            position: 7,
            itemData: Self.payload
        ))
        context.insert(StoreSchemaV1.PersistedRunReportItem(
            key: "report-sentinel",
            runID: Self.runID,
            itemID: Self.workItemID,
            position: 7,
            timestamp: Self.timestamp,
            data: Self.payload
        ))
        context.insert(StoreSchemaV1.PersistedFixPlan(
            planID: Self.planID,
            sourceRunID: Self.runID,
            timestamp: Self.timestamp,
            data: Self.payload
        ))
        context.insert(StoreSchemaV1.PersistedFixPlanDecision(
            planID: Self.planID,
            timestamp: Self.timestamp,
            data: Self.payload
        ))
        try context.save()
    }

    private func fixtureTrack() -> StoreSchemaV1.PersistedTrack {
        let track = StoreSchemaV1.PersistedTrack(
            trackID: "track-sentinel",
            name: "Migration Track",
            artist: "Migration Artist",
            album: "Migration Album"
        )
        track.appleScriptID = "track-sentinel"
        track.genre = "Migration Genre"
        track.year = 2026
        track.genreUpdated = true
        track.yearUpdated = true
        track.processedDate = Self.timestamp
        track.lastError = "migration-error-sentinel"
        track.dateAdded = Self.timestamp
        track.albumArtist = "Migration Album Artist"
        track.trackStatus = "local"
        track.originalArtist = "Original Artist"
        track.originalAlbum = "Original Album"
        track.yearBeforeMGU = 2025
        track.yearSetByMGU = 2026
        track.releaseYear = 2024
        return track
    }

    private func verifyMigratedStore(_ container: ModelContainer, hasMirrorState: Bool) throws {
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
        if hasMirrorState {
            #expect(mirrors.count == 1)
            let mirror = try #require(mirrors.first)
            #expect(try mirror.scopeData == JSONEncoder().encode(MirrorScope.fullLibrary))
            #expect(try mirror.coverage() == .verified(.fullLibrary))
            #expect(mirror.revisionValue == 0)
        } else {
            #expect(mirrors.isEmpty)
        }
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
