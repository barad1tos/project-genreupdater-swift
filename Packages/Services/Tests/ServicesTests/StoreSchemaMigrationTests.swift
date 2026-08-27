import Core
import CoreData
import Foundation
@preconcurrency import SwiftData
import Testing
@testable import Services

@Suite("SwiftData store schema migration", .serialized)
struct StoreSchemaMigrationTests {
    private enum MirrorFixtureState {
        case missing
        case unknown
        case fullLibrary
    }

    private static let preMirrorChecksum = "4gyxaR3XVbJ4CxMo9jcZdflFXNqaKxs0rO8+kkx/1v0="
    private static let mirrorScopeChecksum = "vrVyyiD+OtvleDs7wa27tSGnDMLj4Bts1NWHukp62k4="
    private static let certificateChecksum = "ZSXa0kgQOGc2k4E+9dCVjwRM05iEMOGympXy2vSo6HE="
    private static let deployedMembershipChecksum = "whynwE78EfLk6nFo6Pm4ZxQSXWggha8oemCvJY0LlPw="
    private static let deployedCoverageChecksum = "lCPA7P84tguSr6BvhsyyK+8Wzw49fLJgWhUikSppAIQ="
    private static let recoveryChecksum = "i2Q0M3v/JLttbprhy5I8T0nCkA5O9AYoi9OSQRGpY2s="
    private static let runID = fixtureID("00000000-0000-0000-0000-000000000001")
    private static let workItemID = fixtureID("00000000-0000-0000-0000-000000000002")
    private static let planID = fixtureID("00000000-0000-0000-0000-000000000003")
    private static let changeID = fixtureID("00000000-0000-0000-0000-000000000004")
    private static let requestID = fixtureID("00000000-0000-0000-0000-000000000005")
    private static let recoveryID = fixtureID("00000000-0000-0000-0000-000000000006")
    private static let priorRunID = fixtureID("00000000-0000-0000-0000-000000000007")
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

        try verifyMigratedStore(migratedContainer(at: storeURL), mirrorState: .fullLibrary)
        try verifyMigratedStore(migratedContainer(at: storeURL), mirrorState: .fullLibrary)
    }

    @Test("A pre-mirror store migrates without losing persisted entities")
    func migratesPreMirrorStore() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "GenreUpdater.store")

        try StoreSchemaV0Fixture.write(to: storeURL)
        #expect(try storeChecksum(at: storeURL) == Self.preMirrorChecksum)

        do {
            let container = try migratedContainer(at: storeURL)
            try verifyMigratedStore(container, mirrorState: .missing)
            let store = TrackDataStore(modelContainer: container)
            try await store.initialize()
            let snapshot = try await store.loadMirrorSnapshot()
            #expect(snapshot.certificates.isEmpty)
            #expect(snapshot.revision == .initial)
            try verifyMigratedStore(container, mirrorState: .unknown)
        }
        do {
            let container = try migratedContainer(at: storeURL)
            try verifyMigratedStore(container, mirrorState: .unknown)
            let snapshot = try await TrackDataStore(modelContainer: container).loadMirrorSnapshot()
            #expect(snapshot.certificates.isEmpty)
            #expect(snapshot.revision == .initial)
        }
    }

    @Test("Current membership schema remains reopenable without a version change")
    func pinsMembershipSchema() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "GenreUpdater.store")

        _ = try migratedContainer(at: storeURL)
        let checksum = try storeChecksum(at: storeURL)
        #expect(checksum == Self.certificateChecksum)
        _ = try migratedContainer(at: storeURL)
    }

    @Test("The exact deployed V4 coverage store migrates with no admissible certificates")
    func migratesDeployedCoverageFailClosed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "GenreUpdater.store")

        try FileManager.default.copyItem(at: Self.deployedCoverageFixtureURL, to: storeURL)
        let deployedChecksum = try storeChecksum(at: storeURL)
        #expect(deployedChecksum == Self.deployedCoverageChecksum)

        let reopenEvidence = try verifyCoverageFixture(at: storeURL)
        #expect(reopenEvidence.count == 2)
        for evidence in reopenEvidence {
            let membership = Dictionary(uniqueKeysWithValues: evidence.members.map { ($0.databaseID, $0) })

            #expect(evidence.trackID == "v4-present" && evidence.appleScriptID == "v4-present")
            #expect(evidence.trackName == "Frozen V4 Track" && evidence.artist == "Frozen V4 Artist")
            #expect(evidence.historyTrackID == "v4-present" && evidence.linkedHistoryTrackID == "v4-present")
            #expect(Set(membership.keys) == ["v4-removed", "v4-present"])
            #expect(membership["v4-removed"]?.isPresent == false)
            #expect(membership["v4-removed"]?.lastSeenFingerprint == "frozen-v4-membership")
            #expect(membership["v4-removed"]?.removalRevision == 6)
            #expect(membership["v4-removed"]?.removedAt == Self.timestamp)
            #expect(membership["v4-present"]?.isPresent == true)
            #expect(membership["v4-present"]?.firstSeenRevision == 2)
            #expect(membership["v4-present"]?.lastSeenFingerprint == "frozen-v4-membership")
            #expect(evidence.revision == 7)
            #expect(evidence.presentIDs == ["v4-present"])
            #expect(evidence.presentTrackIDs == ["v4-present"])
            #expect(evidence.certificateCount == 0)
            #expect(evidence.requiresFreshObservation)
        }
    }

    @Test("The deployed V3 membership store migrates without losing membership state")
    func migratesDeployedStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "GenreUpdater.store")
        let removedAt = Date(timeIntervalSince1970: 1_800_000_100)

        _ = try fixtureProcess(mode: "v3", at: storeURL)

        #expect(try storeChecksum(at: storeURL) == Self.deployedMembershipChecksum)
        let reopenEvidence: [V3MigrationEvidence] = try fixtureEvidence(mode: "verify-v3", at: storeURL)
        for evidence in reopenEvidence {
            let member = try #require(evidence.members.first)
            #expect(member.databaseID == "deployed-member")
            #expect(!member.isPresent)
            #expect(member.firstSeenRevision == 7)
            #expect(member.lastSeenFingerprint == "deployed-fingerprint")
            #expect(member.removalRevision == 9)
            #expect(member.removedAt == removedAt)
        }
    }

    @Test("The unversioned recovery store gains canonical membership")
    func migratesRecoveryStoreMembership() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "GenreUpdater.store")

        do {
            let schema = Schema(versionedSchema: StoreSchemaV2.self)
            let configuration = ModelConfiguration(
                "GenreUpdater",
                schema: schema,
                url: storeURL,
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

        var metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType,
            at: storeURL
        )
        metadata[NSPersistentStoreModelVersionChecksumKey] = Self.recoveryChecksum
        try NSPersistentStoreCoordinator.setMetadata(metadata, type: .sqlite, at: storeURL)
        #expect(try storeChecksum(at: storeURL) == Self.recoveryChecksum)
        let store = try TrackDataStore(modelContainer: migratedContainer(at: storeURL))
        try await store.initialize()
        let snapshot = try await store.loadMirrorSnapshot()
        #expect(snapshot.revision == MirrorRevision(value: 7))
        #expect(snapshot.presentTracks.map(\.id) == ["recovery-track"])
    }

    private static var fixtureURL: URL {
        if let override = ProcessInfo.processInfo.environment["GENREUPDATER_V1_FIXTURE_PATH"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "LegacyFixtures/StoreSchemaV1.fixture")
    }

    private static var deployedCoverageFixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "LegacyFixtures/StoreSchemaV4.fixture")
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

    private func verifyCoverageFixture(at storeURL: URL) throws -> [V4MigrationEvidence] {
        try fixtureEvidence(mode: "verify-v4", at: storeURL)
    }

    private func fixtureEvidence<Evidence: Decodable>(mode: String, at storeURL: URL) throws -> Evidence {
        try JSONDecoder().decode(Evidence.self, from: fixtureProcess(mode: mode, at: storeURL))
    }

    private func fixtureProcess(mode: String, at storeURL: URL) throws -> Data {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = try fixtureGeneratorURL()
        process.arguments = [mode, storeURL.path]
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = standardError.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw FixtureProcessError.failed(
                status: process.terminationStatus,
                message: String(data: errorOutput, encoding: .utf8) ?? "<non-UTF-8 output>"
            )
        }
        return output
    }

    private func fixtureGeneratorURL() throws -> URL {
        let packageDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidate = packageDirectory.appending(path: ".build/debug/StoreFixtureGenerator")
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw FixtureProcessError.executableNotFound
    }

    private func verifyMigratedStore(_ container: ModelContainer, mirrorState: MirrorFixtureState) throws {
        let context = ModelContext(container)
        try verifyTrackState(context)
        try verifyMirrorState(context, expected: mirrorState)
        try verifyLibraryState(context)
        try verifyRunState(context)
        try verifyFixPlanState(context)
    }

    private func verifyTrackState(_ context: ModelContext) throws {
        let tracks = try context.fetch(FetchDescriptor<PersistedTrack>())
        let track = try #require(tracks.first)
        #expect(tracks.count == 1)
        #expect(track.trackID == "track-sentinel")
        #expect(track.appleScriptID == "track-sentinel")
        #expect(track.name == "Migration Track")
        #expect(track.artist == "Migration Artist")
        #expect(track.album == "Migration Album")
        #expect(track.genre == "Migration Genre")
        #expect(track.year == 2026)
        #expect(track.genreUpdated && track.yearUpdated)
        #expect(track.processedDate == Self.timestamp)
        #expect(track.lastError == "migration-error-sentinel")
        #expect(track.dateAdded == Self.timestamp)
        #expect(track.albumArtist == "Migration Album Artist")
        #expect(track.trackStatus == "local")
        #expect(track.originalArtist == "Original Artist")
        #expect(track.originalAlbum == "Original Album")
        #expect(track.yearBeforeMGU == 2025)
        #expect(track.yearSetByMGU == 2026)
        #expect(track.releaseYear == 2024)
        #expect(track.changeLog.map(\.entryID) == [Self.changeID])

        let changes = try context.fetch(FetchDescriptor<PersistedChangeLogEntry>())
        let change = try #require(changes.first)
        #expect(changes.count == 1)
        #expect(change.timestamp == Self.timestamp)
        #expect(change.changeTypeRaw == "artistRename")
        #expect(change.trackID == "track-sentinel")
        #expect(change.artist == "Migration Artist")
        #expect(change.trackName == "Migration Track")
        #expect(change.albumName == "Migration Album")
        #expect(change.oldGenre == "Old Genre" && change.newGenre == "Migration Genre")
        #expect(change.oldYear == 2025 && change.newYear == 2026)
        #expect(change.oldTrackName == "Old Track" && change.newTrackName == "Migration Track")
        #expect(change.oldAlbumName == "Old Album" && change.newAlbumName == "Migration Album")
        #expect(change.oldArtist == "Original Artist" && change.newArtist == "Migration Artist")
        #expect(change.oldAlbumArtist == "Original Album Artist")
        #expect(change.newAlbumArtist == "Migration Album Artist")
        #expect(change.runID == Self.runID)
        #expect(change.track?.trackID == "track-sentinel")
    }

    private func verifyMirrorState(_ context: ModelContext, expected: MirrorFixtureState) throws {
        let mirrors = try context.fetch(FetchDescriptor<PersistedMirrorState>())
        guard expected != .missing else {
            #expect(mirrors.isEmpty)
            return
        }
        #expect(mirrors.count == 1)
        let mirror = try #require(mirrors.first)
        #expect(mirror.revisionValue == 0)
        #expect(try context.fetch(FetchDescriptor<PersistedScopeCertificate>()).isEmpty)
    }

    private func verifyLibraryState(_ context: ModelContext) throws {
        let metrics = try context.fetch(FetchDescriptor<PersistedMetricsSnapshot>())
        let pendingAlbums = try context.fetch(FetchDescriptor<PersistedPendingAlbumEntry>())
        let pendingMetadata = try context.fetch(FetchDescriptor<PersistedPendingVerificationMetadata>())
        let metric = try #require(metrics.first)
        #expect(metrics.count == 1)
        #expect(metric.totalTracks == 11)
        #expect(metric.tracksWithGenre == 10 && metric.tracksWithYear == 9 && metric.tracksWithBoth == 8)
        #expect(metric.tracksNeedingGenre == 1 && metric.tracksNeedingYear == 2)
        #expect(metric.protectedFileCount == 3 && metric.recentlyAdded == 4)
        #expect(metric.timestamp == Self.timestamp)
        #expect(metric.previousTotalTracks == 7)
        #expect(metric.previousTracksNeedingGenre == 6 && metric.previousTracksNeedingYear == 5)
        #expect(metric.previousRecentlyAdded == 4)

        let pending = try #require(pendingAlbums.first)
        #expect(pendingAlbums.count == 1)
        #expect(pending.entryID == "pending-sentinel")
        #expect(pending.artist == "Pending Artist" && pending.album == "Pending Album")
        #expect(pending.reason == "prerelease" && pending.attemptCount == 3)
        #expect(pending.lastAttempt == Self.timestamp && pending.recheckInterval == 86400)
        #expect(pending.metadataData == Self.payload)
        #expect(pendingMetadata.count == 1)
        #expect(pendingMetadata.first?.metadataID == "pending-verification")
        #expect(pendingMetadata.first?.lastAutoVerification == Self.timestamp)
    }

    private func verifyRunState(_ context: ModelContext) throws {
        let runs = try context.fetch(FetchDescriptor<PersistedRunRecord>())
        let workItems = try context.fetch(FetchDescriptor<PersistedRunWorkItem>())
        let reportItems = try context.fetch(FetchDescriptor<PersistedRunReportItem>())
        let run = try #require(runs.first)
        #expect(runs.count == 1)
        #expect(run.runID == Self.runID && run.requestID == Self.requestID)
        #expect(run.triggerRaw == "manualRun" && run.intentRaw == "write" && run.stateRaw == "failed")
        #expect(run.writeAuthorityRaw == "approved")
        #expect(run.recoveryID == Self.recoveryID && run.continuesRunID == Self.priorRunID)
        #expect(run.scopeData == Self.payload && run.transitionsData == Self.payload)
        #expect(run.syncNewCount == 1 && run.syncModifiedCount == 2)
        #expect(run.syncIdentityChangedCount == 3 && run.syncRefreshedCount == 4 && run.syncRemovedCount == 5)
        #expect(run.failureMessage == "migration-failure-sentinel")
        #expect(run.startedAt == Self.timestamp && run.finishedAt == Self.timestamp)

        let work = try #require(workItems.first)
        #expect(workItems.count == 1)
        #expect(work.key == "work-sentinel" && work.runID == Self.runID)
        #expect(work.itemID == Self.workItemID && work.position == 7 && work.itemData == Self.payload)

        let report = try #require(reportItems.first)
        #expect(reportItems.count == 1)
        #expect(report.key == "report-sentinel" && report.runID == Self.runID)
        #expect(report.itemID == Self.workItemID && report.position == 7)
        #expect(report.runStartedAt == Self.timestamp)
        #expect(report.changeTypeRaw == "genreUpdate" && report.stateRaw == "prepared")
        #expect(report.artist == "Report Artist" && report.album == "Report Album")
        #expect(report.trackName == "Report Track" && report.targetKindRaw == "track")
        #expect(report.itemData == Self.payload)
    }

    private func verifyFixPlanState(_ context: ModelContext) throws {
        let plans = try context.fetch(FetchDescriptor<PersistedFixPlan>())
        let decisions = try context.fetch(FetchDescriptor<PersistedFixPlanDecision>())
        let plan = try #require(plans.first)
        #expect(plans.count == 1)
        #expect(plan.planID == Self.planID && plan.revision == 1 && plan.sourceRunID == Self.runID)
        #expect(plan.createdAt == Self.timestamp)
        #expect(plan.configSnapshotData == Self.payload && plan.scopeSnapshotData == Self.payload)
        #expect(plan.itemsData == Self.payload && plan.itemCount == 0)
        #expect(plan.scopeSource == "fullLibrary" && plan.configFingerprint == "fixture")

        let decision = try #require(decisions.first)
        #expect(decisions.count == 1)
        #expect(decision.planID == Self.planID)
        #expect(decision.planRevision == 1 && decision.decisionRevision == 1)
        #expect(decision.decidedAt == Self.timestamp && decision.itemDecisionsData == Self.payload)
    }
}

private enum FixtureProcessError: LocalizedError {
    case executableNotFound
    case failed(status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "StoreFixtureGenerator was not found beside the Services test product."
        case let .failed(status, message):
            "StoreFixtureGenerator failed with status \(status): \(message)"
        }
    }
}
