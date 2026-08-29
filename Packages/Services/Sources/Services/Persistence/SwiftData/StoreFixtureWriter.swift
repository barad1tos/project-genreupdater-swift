import Core
import Foundation
import SwiftData

/// Writes synthetic legacy stores for migration tests and checked-in fixtures.
package enum StoreFixtureWriter {
    package static func writeV0(to storeURL: URL) throws {
        let schema = Schema(versionedSchema: StoreSchemaV0.self)
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
        let change = fixtureChange(track: track)
        track.changeLog = [change]

        context.insert(track)
        context.insert(change)
        context.insert(fixtureMetrics())
        context.insert(fixturePendingAlbum())
        context.insert(StoreSchemaV1.PersistedPendingVerificationMetadata(lastAutoVerification: timestamp))
        insertRunState(into: context)
        insertFixPlan(into: context)
        try context.save()
    }

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
        let scopeData = try JSONEncoder().encode([String]())
        let track = fixtureTrack()
        let change = fixtureChange(track: track)
        track.changeLog = [change]

        insertLibraryState(into: context, track: track, change: change, scopeData: scopeData)
        insertRunState(into: context)
        insertFixPlan(into: context)
        try context.save()
    }

    package static func writeV3(to storeURL: URL) throws {
        let schema = Schema(versionedSchema: StoreSchemaV3.self)
        let configuration = ModelConfiguration(
            "GenreUpdater",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.insert(StoreSchemaV3.PersistedLibraryMember(
            databaseID: "deployed-member",
            isPresent: false,
            firstSeenRevisionValue: 7,
            lastSeenMembershipFingerprint: "deployed-fingerprint",
            removalRevisionValue: 9,
            removedAt: Date(timeIntervalSince1970: 1_800_000_100)
        ))
        try context.save()
    }

    package static func writeV4(to storeURL: URL) throws {
        let schema = Schema(versionedSchema: StoreSchemaV4.self)
        let configuration = ModelConfiguration(
            "GenreUpdater",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let track = StoreSchemaV2.PersistedTrack(
            trackID: "v4-present",
            appleScriptID: "v4-present",
            name: "Frozen V4 Track",
            artist: "Frozen V4 Artist",
            album: "Frozen V4 Album"
        )
        let change = StoreSchemaV2.PersistedChangeLogEntry(
            entryID: changeID,
            timestamp: timestamp,
            changeTypeRaw: "genre",
            trackID: track.trackID,
            artist: track.artist,
            trackName: track.name,
            albumName: track.album,
            oldGenre: "Old Genre",
            newGenre: "Frozen Genre"
        )
        change.track = track
        track.changeLog = [change]

        context.insert(track)
        context.insert(change)
        try context.insert(StoreSchemaV2.PersistedMirrorState(
            scopeData: JSONEncoder().encode(["Frozen V4 Artist"]),
            revisionValue: 7
        ))
        context.insert(StoreSchemaV4.PersistedLibraryMember(
            databaseID: "v4-present",
            isPresent: true,
            firstSeenRevisionValue: 2,
            lastSeenFingerprint: "frozen-v4-membership"
        ))
        context.insert(StoreSchemaV4.PersistedLibraryMember(
            databaseID: "v4-removed",
            isPresent: false,
            firstSeenRevisionValue: 1,
            lastSeenFingerprint: "frozen-v4-membership",
            removalRevisionValue: 6,
            removedAt: timestamp
        ))
        try context.save()
    }

    package static func writeInterruptedV4(to storeURL: URL) throws {
        let schema = Schema(versionedSchema: StoreSchemaV4.self)
        let configuration = ModelConfiguration(
            "GenreUpdater",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.insert(StoreSchemaV2.PersistedTrack(
            trackID: "interrupted-member",
            appleScriptID: "interrupted-member",
            name: "Interrupted Track",
            artist: "Interrupted Artist",
            album: "Interrupted Album"
        ))
        context.insert(StoreSchemaV2.PersistedMirrorState(scopeData: nil, revisionValue: 7))
        try context.save()
    }

    package static func writeV5(to storeURL: URL) throws {
        let schema = Schema(versionedSchema: StoreSchemaV5.self)
        let configuration = ModelConfiguration(
            "GenreUpdater",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.insert(StoreSchemaV5.PersistedMirrorState(revisionValue: 11))
        context.insert(StoreSchemaV4.PersistedLibraryMember(
            databaseID: "v5-present",
            isPresent: true,
            firstSeenRevisionValue: 3,
            lastSeenFingerprint: "v5-membership"
        ))
        try context.save()
    }

    package static func writeRecoveryV2(to storeURL: URL) throws {
        let schema = Schema(versionedSchema: StoreSchemaV2.self)
        let configuration = ModelConfiguration(
            "GenreUpdater",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.insert(PersistedTrack(
            trackID: "recovery-track",
            appleScriptID: "recovery-track",
            name: "Recovery Track",
            artist: "Recovery Artist",
            album: "Recovery Album"
        ))
        context.insert(StoreSchemaV2.PersistedMirrorState(scopeData: nil, revisionValue: 7))
        try context.save()
    }

    package static func writeMembershipV2(to storeURL: URL) throws {
        let schema = Schema(versionedSchema: StoreSchemaV2.self)
        let configuration = ModelConfiguration(
            "GenreUpdater",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let canonical = StoreSchemaV2.PersistedTrack(
            trackID: "canonical",
            appleScriptID: "canonical",
            name: "Canonical",
            artist: "Artist",
            album: "Album"
        )
        let catalog = StoreSchemaV2.PersistedTrack(
            trackID: "catalog",
            appleScriptID: "database",
            name: "Catalog",
            artist: "Artist",
            album: "Album"
        )
        let history = StoreSchemaV2.PersistedChangeLogEntry(
            entryID: changeID,
            timestamp: timestamp,
            changeTypeRaw: ChangeType.genreUpdate.rawValue,
            trackID: canonical.trackID,
            artist: canonical.artist,
            trackName: canonical.name,
            albumName: canonical.album
        )
        history.track = canonical
        canonical.changeLog = [history]

        context.insert(StoreSchemaV2.PersistedMirrorState(scopeData: nil, revisionValue: 7))
        context.insert(canonical)
        context.insert(catalog)
        context.insert(history)
        try context.save()
    }

    private static let runID = identifier("00000000-0000-0000-0000-000000000001")
    private static let workItemID = identifier("00000000-0000-0000-0000-000000000002")
    private static let planID = identifier("00000000-0000-0000-0000-000000000003")
    private static let changeID = identifier("00000000-0000-0000-0000-000000000004")
    private static let requestID = identifier("00000000-0000-0000-0000-000000000005")
    private static let recoveryID = identifier("00000000-0000-0000-0000-000000000006")
    private static let priorRunID = identifier("00000000-0000-0000-0000-000000000007")
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
        context.insert(fixtureMetrics())
        context.insert(fixturePendingAlbum())
        context.insert(StoreSchemaV1.PersistedPendingVerificationMetadata(lastAutoVerification: timestamp))
    }

    private static func insertRunState(into context: ModelContext) {
        context.insert(fixtureRun())
        context.insert(StoreSchemaV1.PersistedRunWorkItem(
            key: "work-sentinel",
            runID: runID,
            itemID: workItemID,
            position: 7,
            itemData: payload
        ))
        let report = StoreSchemaV1.PersistedRunReportItem(
            key: "report-sentinel",
            runID: runID,
            itemID: workItemID,
            position: 7,
            timestamp: timestamp,
            data: payload
        )
        report.artist = "Report Artist"
        report.album = "Report Album"
        report.trackName = "Report Track"
        report.targetKindRaw = "track"
        context.insert(report)
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
        track.processedDate = timestamp
        track.lastError = "migration-error-sentinel"
        track.dateAdded = timestamp
        track.albumArtist = "Migration Album Artist"
        track.trackStatus = "local"
        track.originalArtist = "Original Artist"
        track.originalAlbum = "Original Album"
        track.yearBeforeMGU = 2025
        track.yearSetByMGU = 2026
        track.releaseYear = 2024
        return track
    }

    private static func fixtureChange(
        track: StoreSchemaV1.PersistedTrack
    ) -> StoreSchemaV1.PersistedChangeLogEntry {
        let change = StoreSchemaV1.PersistedChangeLogEntry(
            entryID: changeID,
            timestamp: timestamp,
            trackID: track.trackID,
            track: track
        )
        change.changeTypeRaw = "artistRename"
        change.artist = "Migration Artist"
        change.trackName = "Migration Track"
        change.albumName = "Migration Album"
        change.oldGenre = "Old Genre"
        change.newGenre = "Migration Genre"
        change.oldYear = 2025
        change.newYear = 2026
        change.oldTrackName = "Old Track"
        change.newTrackName = "Migration Track"
        change.oldAlbumName = "Old Album"
        change.newAlbumName = "Migration Album"
        change.oldArtist = "Original Artist"
        change.newArtist = "Migration Artist"
        change.oldAlbumArtist = "Original Album Artist"
        change.newAlbumArtist = "Migration Album Artist"
        change.runID = runID
        return change
    }

    private static func fixtureMetrics() -> StoreSchemaV1.PersistedMetricsSnapshot {
        let metrics = StoreSchemaV1.PersistedMetricsSnapshot(totalTracks: 11, timestamp: timestamp)
        metrics.tracksWithGenre = 10
        metrics.tracksWithYear = 9
        metrics.tracksWithBoth = 8
        metrics.tracksNeedingGenre = 1
        metrics.tracksNeedingYear = 2
        metrics.protectedFileCount = 3
        metrics.recentlyAdded = 4
        metrics.previousTotalTracks = 7
        metrics.previousTracksNeedingGenre = 6
        metrics.previousTracksNeedingYear = 5
        metrics.previousRecentlyAdded = 4
        return metrics
    }

    private static func fixturePendingAlbum() -> StoreSchemaV1.PersistedPendingAlbumEntry {
        let pending = StoreSchemaV1.PersistedPendingAlbumEntry(
            entryID: "pending-sentinel",
            timestamp: timestamp
        )
        pending.artist = "Pending Artist"
        pending.album = "Pending Album"
        pending.reason = "prerelease"
        pending.attemptCount = 3
        pending.recheckInterval = 86400
        pending.metadataData = payload
        return pending
    }

    private static func fixtureRun() -> StoreSchemaV1.PersistedRunRecord {
        let run = StoreSchemaV1.PersistedRunRecord(
            runID: runID,
            data: payload,
            timestamp: timestamp
        )
        run.requestID = requestID
        run.triggerRaw = "manualRun"
        run.intentRaw = "write"
        run.stateRaw = "failed"
        run.writeAuthorityRaw = "approved"
        run.recoveryID = recoveryID
        run.continuesRunID = priorRunID
        run.syncNewCount = 1
        run.syncModifiedCount = 2
        run.syncIdentityChangedCount = 3
        run.syncRefreshedCount = 4
        run.syncRemovedCount = 5
        run.failureMessage = "migration-failure-sentinel"
        run.finishedAt = timestamp
        return run
    }

    private static func identifier(_ value: String) -> UUID {
        guard let identifier = UUID(uuidString: value) else {
            preconditionFailure("Invalid synthetic migration fixture UUID")
        }
        return identifier
    }
}
