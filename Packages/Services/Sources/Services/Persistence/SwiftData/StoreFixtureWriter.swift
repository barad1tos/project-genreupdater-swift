import Core
import Foundation
import SwiftData

/// Writes the synthetic V1 store consumed by the checked-in migration fixture.
package enum StoreFixtureWriter {
    package static func writeV1(to storeURL: URL) throws {
        let schema = Schema(versionedSchema: StoreSchemaV1.self)
        let configuration = ModelConfiguration(
            "GenreUpdater",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let scopeData = try JSONEncoder().encode(MirrorScope.fullLibrary)
        let track = fixtureTrack()
        let change = StoreSchemaV1.PersistedChangeLogEntry(
            entryID: changeID,
            timestamp: timestamp,
            trackID: track.trackID,
            track: track
        )
        track.changeLog = [change]

        insertLibraryState(into: context, track: track, change: change, scopeData: scopeData)
        insertRunState(into: context)
        insertFixPlan(into: context)
        try context.save()
    }

    private static let runID = identifier("00000000-0000-0000-0000-000000000001")
    private static let workItemID = identifier("00000000-0000-0000-0000-000000000002")
    private static let planID = identifier("00000000-0000-0000-0000-000000000003")
    private static let changeID = identifier("00000000-0000-0000-0000-000000000004")
    private static let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
    private static let payload = Data("migration-sentinel".utf8)

    private static func insertLibraryState(
        into context: ModelContext,
        track: StoreSchemaV1.PersistedTrack,
        change: StoreSchemaV1.PersistedChangeLogEntry,
        scopeData: Data
    ) {
        context.insert(track)
        context.insert(change)
        context.insert(StoreSchemaV1.PersistedMirrorState(scopeData: scopeData))
        context.insert(StoreSchemaV1.PersistedMetricsSnapshot(totalTracks: 1, timestamp: timestamp))
        context.insert(StoreSchemaV1.PersistedPendingAlbumEntry(entryID: "pending-sentinel", timestamp: timestamp))
        context.insert(StoreSchemaV1.PersistedPendingVerificationMetadata(lastAutoVerification: timestamp))
    }

    private static func insertRunState(into context: ModelContext) {
        context.insert(StoreSchemaV1.PersistedRunRecord(
            runID: runID,
            data: payload,
            timestamp: timestamp
        ))
        context.insert(StoreSchemaV1.PersistedRunWorkItem(
            key: "work-sentinel",
            runID: runID,
            itemID: workItemID,
            position: 7,
            itemData: payload
        ))
        context.insert(StoreSchemaV1.PersistedRunReportItem(
            key: "report-sentinel",
            runID: runID,
            itemID: workItemID,
            position: 7,
            timestamp: timestamp,
            data: payload
        ))
    }

    private static func insertFixPlan(into context: ModelContext) {
        context.insert(StoreSchemaV1.PersistedFixPlan(
            planID: planID,
            sourceRunID: runID,
            timestamp: timestamp,
            data: payload
        ))
        context.insert(StoreSchemaV1.PersistedFixPlanDecision(
            planID: planID,
            timestamp: timestamp,
            data: payload
        ))
    }

    private static func fixtureTrack() -> StoreSchemaV1.PersistedTrack {
        StoreSchemaV1.PersistedTrack(
            trackID: "track-sentinel",
            appleScriptID: "track-sentinel",
            name: "Migration Track",
            artist: "Migration Artist",
            album: "Migration Album",
            genre: "Migration Genre",
            year: 2026,
            genreUpdated: true,
            yearUpdated: true,
            processedDate: timestamp,
            lastError: "migration-error-sentinel",
            dateAdded: timestamp,
            albumArtist: "Migration Album Artist",
            trackStatus: "local",
            originalArtist: "Original Artist",
            originalAlbum: "Original Album",
            yearBeforeMGU: 2025,
            yearSetByMGU: 2026,
            releaseYear: 2024
        )
    }

    private static func identifier(_ value: String) -> UUID {
        guard let identifier = UUID(uuidString: value) else {
            preconditionFailure("Invalid synthetic migration fixture UUID")
        }
        return identifier
    }
}
