import Core
import CoreData
import Darwin
import Foundation
@preconcurrency import SwiftData
import Testing
@testable import Services

@Suite("SwiftData store schema migration")
struct StoreSchemaMigrationTests {
    private enum MirrorFixtureState {
        case missing
        case unknown
        case fullLibrary
    }

    private static let preMirrorChecksum = "4gyxaR3XVbJ4CxMo9jcZdflFXNqaKxs0rO8+kkx/1v0="
    private static let mirrorScopeChecksum = "vrVyyiD+OtvleDs7wa27tSGnDMLj4Bts1NWHukp62k4="
    private static let syncRecordChecksum = "rlZMfluVDEVAON7i25ASHKftyiB+kOiR6nxIjVb7Cm4="
    private static let deployedMembershipChecksum = "whynwE78EfLk6nFo6Pm4ZxQSXWggha8oemCvJY0LlPw="
    private static let deployedCoverageChecksum = "lCPA7P84tguSr6BvhsyyK+8Wzw49fLJgWhUikSppAIQ="
    private static let deployedV6Checksum = "RjRJxmJfhLjdHHhDRUvRjn2jqm3L/8ZpduaKKgTfRns="
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
        _ = try fixtureProcess(mode: "migrate", at: storeURL)

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

        _ = try fixtureProcess(mode: "v0", at: storeURL)
        #expect(try storeChecksum(at: storeURL) == Self.preMirrorChecksum)
        _ = try fixtureProcess(mode: "migrate", at: storeURL)

        do {
            let container = try migratedContainer(at: storeURL)
            try verifyMigratedStore(container, mirrorState: .missing)
            let store = TrackDataStore(modelContainer: container)
            try await store.initialize()
            let snapshot = try await store.loadMirrorSnapshot()
            #expect(snapshot.certificates.isEmpty)
            #expect(snapshot.revision == .initial)
            #expect(snapshot.presentIDs.map(\.rawValue) == ["track-sentinel"])
            #expect(snapshot.presentTracks.map(\.id) == ["track-sentinel"])
            try verifyMigratedStore(container, mirrorState: .unknown)
        }
        do {
            let container = try migratedContainer(at: storeURL)
            try verifyMigratedStore(container, mirrorState: .unknown)
            let snapshot = try await TrackDataStore(modelContainer: container).loadMirrorSnapshot()
            #expect(snapshot.certificates.isEmpty)
            #expect(snapshot.revision == .initial)
            #expect(snapshot.presentIDs.map(\.rawValue) == ["track-sentinel"])
            #expect(snapshot.presentTracks.map(\.id) == ["track-sentinel"])
        }
    }

    @Test("Current synchronization schema remains reopenable without a version change")
    func pinsSyncRecordSchema() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "GenreUpdater.store")

        _ = try migratedContainer(at: storeURL)
        let checksum = try storeChecksum(at: storeURL)
        #expect(checksum == Self.syncRecordChecksum)
        let reopened = try migratedContainer(at: storeURL)
        let context = ModelContext(reopened)
        #expect(reopened.migrationPlan == nil)
        #expect(try context.fetch(FetchDescriptor<PersistedLibraryMember>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<PersistedScopeCertificate>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<PersistedSyncRecord>()).isEmpty)
    }

    @Test("V5 members migrate with unknown identity and remain reopenable")
    func migratesV5IdentityFailClosed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "GenreUpdater.store")

        _ = try fixtureProcess(mode: "v5", at: storeURL)

        for _ in 0 ..< 2 {
            let container = try migratedContainer(at: storeURL)
            let context = ModelContext(container)
            let member = try #require(context.fetch(FetchDescriptor<PersistedLibraryMember>()).first)
            #expect(member.databaseID == "v5-present")
            #expect(member.isPresent)
            #expect(member.firstSeenRevisionValue == 3)
            #expect(member.lastSeenFingerprint == "v5-membership")
            #expect(member.artist == nil)
            #expect(member.albumArtist == nil)
            #expect(member.identityObservedAt == nil)
            #expect(member.identityRevisionValue == nil)
            #expect(try context.fetch(FetchDescriptor<PersistedScopeCertificate>()).isEmpty)

            let snapshot = try await TrackDataStore(modelContainer: container).loadMirrorSnapshot()
            #expect(snapshot.revision == MirrorRevision(value: 11))
            #expect(snapshot.presentIDs.map(\.rawValue) == ["v5-present"])
            #expect(snapshot.memberIdentities.isEmpty)
            #expect(snapshot.certificates.isEmpty)
        }
    }

    @Test("V6 mirror state migrates to V7 with empty synchronization history")
    func migratesV6SyncHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "GenreUpdater.store")

        try FileManager.default.copyItem(at: Self.deployedV6FixtureURL, to: storeURL)
        #expect(try storeChecksum(at: storeURL) == Self.deployedV6Checksum)

        for _ in 0 ..< 2 {
            let container = try migratedContainer(at: storeURL)
            let snapshot = try await TrackDataStore(modelContainer: container).loadMirrorSnapshot()
            let context = ModelContext(container)
            let member = try #require(context.fetch(FetchDescriptor<PersistedLibraryMember>()).first)

            #expect(snapshot.revision == MirrorRevision(value: 13))
            #expect(snapshot.presentIDs.map(\.rawValue) == ["v6-present"])
            #expect(snapshot.certificates.isEmpty)
            #expect(member.databaseID == "v6-present")
            #expect(member.isPresent)
            #expect(member.firstSeenRevisionValue == 3)
            #expect(member.lastSeenFingerprint == "v6-membership")
            #expect(try context.fetch(FetchDescriptor<PersistedSyncRecord>()).isEmpty)
        }
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
            #expect(evidence.usesAutomaticMigration)
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
            #expect(evidence.usesAutomaticMigration)
        }
    }

    @Test("V2 membership migration preserves canonical evidence across relaunch")
    func migratesV2Membership() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "GenreUpdater.store")

        _ = try fixtureProcess(mode: "v2-membership", at: storeURL)
        let reopenEvidence: [MembershipMigrationEvidence] = try fixtureEvidence(
            mode: "verify-v2-membership",
            at: storeURL
        )

        #expect(reopenEvidence.count == 2)
        for evidence in reopenEvidence {
            let member = try #require(evidence.members.first)
            #expect(evidence.members.count == 1)
            #expect(member.databaseID == "canonical")
            #expect(member.isPresent)
            #expect(member.firstSeenRevision == 7)
            #expect(member.lastSeenFingerprint == nil)
            #expect(evidence.trackIDs == ["canonical", "catalog"])
            #expect(evidence.historyEntryIDs == [Self.changeID])
            #expect(evidence.certificateCount == 0)
            #expect(evidence.usesAutomaticMigration)
        }
    }

    @Test("Interrupted legacy membership preparation resumes safely")
    func resumesMembershipBootstrap() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "GenreUpdater.store")

        _ = try fixtureProcess(mode: "v4-interrupted", at: storeURL)
        let reopenEvidence: [MembershipMigrationEvidence] = try fixtureEvidence(
            mode: "verify-v2-membership",
            at: storeURL
        )

        #expect(reopenEvidence.count == 2)
        for evidence in reopenEvidence {
            let member = try #require(evidence.members.first)
            #expect(evidence.members.count == 1)
            #expect(member.databaseID == "interrupted-member")
            #expect(member.isPresent)
            #expect(member.firstSeenRevision == 7)
            #expect(evidence.trackIDs == ["interrupted-member"])
            #expect(evidence.certificateCount == 0)
            #expect(evidence.usesAutomaticMigration)
        }
    }

    @Test("Concurrent processes serialize legacy preparation and preserve V5 rows")
    func coordinatesStoreProcesses() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "GenreUpdater.store")
        let lockURL = storeURL.appendingPathExtension("migration.lock")

        try FileManager.default.copyItem(at: Self.fixtureURL, to: storeURL)
        let lockDescriptor = try acquireLock(at: lockURL)
        defer { Darwin.close(lockDescriptor) }
        let firstMigration = try startFixtureProcess(mode: "migrate", at: storeURL)
        let secondMigration = try startFixtureProcess(mode: "migrate", at: storeURL)
        defer {
            firstMigration.cleanup()
            secondMigration.cleanup()
        }

        #expect(processesRemainRunning([firstMigration, secondMigration], for: 2))
        try #require(flock(lockDescriptor, LOCK_UN) == 0)
        _ = try firstMigration.wait()
        _ = try secondMigration.wait()

        let initialEvidence: [MembershipMigrationEvidence] = try fixtureEvidence(
            mode: "verify-v2-membership",
            at: storeURL
        )
        assertConcurrentEvidence(initialEvidence, certificateCount: 0)

        _ = try fixtureProcess(mode: "seed-certificate", at: storeURL)

        let firstReopen = try startFixtureProcess(mode: "migrate", at: storeURL)
        let secondReopen = try startFixtureProcess(mode: "migrate", at: storeURL)
        defer {
            firstReopen.cleanup()
            secondReopen.cleanup()
        }
        _ = try firstReopen.wait()
        _ = try secondReopen.wait()

        let finalEvidence: [MembershipMigrationEvidence] = try fixtureEvidence(
            mode: "verify-v2-membership",
            at: storeURL
        )
        assertConcurrentEvidence(finalEvidence, certificateCount: 1)
    }

    @Test("Same-process openers coalesce per store URL")
    func coalescesStoreOpeners() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "GenreUpdater.store")
        let evidence: ConcurrentOpenEvidence = try fixtureEvidence(
            mode: "verify-concurrent-open",
            at: storeURL
        )
        #expect(evidence.isBlocked)
        #expect(evidence.isFinished)
        #expect(evidence.openCount == 2)
        #expect(evidence.hasOneContainer)
        #expect(evidence.sameURLErrors.isEmpty)
        #expect(evidence.canOpenOther)
        #expect(evidence.otherURLOpenCount == 1)
        #expect(evidence.otherURLErrors.isEmpty)
    }

    @Test("Current stores never infer membership from track rows", arguments: [nil, false])
    func skipsCurrentInference(isPresent: Bool?) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "GenreUpdater.store")

        try writeCurrentStore(at: storeURL, isPresent: isPresent)
        let container = try migratedContainer(at: storeURL)
        try await TrackDataStore(modelContainer: container).initialize()
        let context = ModelContext(container)
        let members = try context.fetch(FetchDescriptor<PersistedLibraryMember>())

        #expect(container.migrationPlan == nil)
        if isPresent == nil {
            #expect(members.isEmpty)
        } else {
            let member = try #require(members.first)
            #expect(members.count == 1)
            #expect(!member.isPresent)
            #expect(member.removalRevisionValue == 7)
        }
        #expect(try context.fetch(FetchDescriptor<PersistedScopeCertificate>()).isEmpty)
    }

    @Test("Fixture process drains large diagnostics before reporting failure")
    func capturesLargeFailure() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "UnusedFixture-\(UUID().uuidString).store")

        do {
            _ = try fixtureProcess(mode: "diagnostic-failure", at: storeURL)
            Issue.record("Expected the diagnostic fixture process to fail")
        } catch let FixtureProcessError.failed(reason, status, standardOutput, standardError) {
            #expect(reason == .uncaughtSignal)
            #expect(status != 0)
            #expect(standardOutput.utf8.count > 65536)
            #expect(standardError.utf8.count > 65536)
            #expect(standardOutput.contains("fixture-stdout-complete"))
            #expect(standardError.contains("fixture-stderr-complete"))
        }
    }

    @Test("The unversioned recovery store gains canonical membership")
    func migratesRecoveryStoreMembership() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "GenreUpdater.store")

        _ = try fixtureProcess(mode: "v2-recovery", at: storeURL)

        var metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType,
            at: storeURL
        )
        metadata[NSPersistentStoreModelVersionChecksumKey] = Self.recoveryChecksum
        try NSPersistentStoreCoordinator.setMetadata(metadata, type: .sqlite, at: storeURL)
        #expect(try storeChecksum(at: storeURL) == Self.recoveryChecksum)
        _ = try fixtureProcess(mode: "migrate", at: storeURL)
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

    private static var deployedV6FixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "LegacyFixtures/StoreSchemaV6.fixture")
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

    private func acquireLock(at lockURL: URL) throws -> Int32 {
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        try #require(descriptor >= 0)
        try #require(flock(descriptor, LOCK_EX) == 0)
        return descriptor
    }

    private func processesRemainRunning(_ processes: [RunningFixtureProcess], for seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            guard processes.allSatisfy(\.isRunning) else { return false }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return processes.allSatisfy(\.isRunning)
    }

    private func assertConcurrentEvidence(
        _ evidence: [MembershipMigrationEvidence],
        certificateCount: Int
    ) {
        #expect(evidence.count == 2)
        for pass in evidence {
            #expect(pass.members.count == 1)
            #expect(pass.members.first?.databaseID == "track-sentinel")
            #expect(pass.members.first?.isPresent == true)
            #expect(pass.members.first?.firstSeenRevision == 0)
            #expect(pass.trackIDs == ["track-sentinel"])
            #expect(pass.certificateCount == certificateCount)
            #expect(pass.usesAutomaticMigration)
        }
    }

    private func writeCurrentStore(at storeURL: URL, isPresent: Bool?) throws {
        let schema = ModelContainerFactory.makeSchema()
        let configuration = ModelConfiguration(
            "GenreUpdater",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.insert(PersistedTrack(
            trackID: "current-track",
            appleScriptID: "current-track",
            name: "Current Track",
            artist: "Current Artist",
            album: "Current Album"
        ))
        if let isPresent {
            context.insert(PersistedMirrorState(revisionValue: 8))
            let member = PersistedLibraryMember(
                databaseID: "current-track",
                isPresent: isPresent,
                firstSeenRevisionValue: 3
            )
            if !isPresent {
                member.markRemoved(revision: MirrorRevision(value: 7), at: Self.timestamp)
            }
            context.insert(member)
        }
        try context.save()
    }

    private func verifyCoverageFixture(at storeURL: URL) throws -> [V4MigrationEvidence] {
        try fixtureEvidence(mode: "verify-v4", at: storeURL)
    }

    private func fixtureEvidence<Evidence: Decodable>(mode: String, at storeURL: URL) throws -> Evidence {
        try JSONDecoder().decode(Evidence.self, from: fixtureProcess(mode: mode, at: storeURL))
    }

    private func fixtureProcess(mode: String, at storeURL: URL) throws -> Data {
        let process = try startFixtureProcess(mode: mode, at: storeURL)
        defer { process.cleanup() }
        return try process.wait()
    }

    private func startFixtureProcess(mode: String, at storeURL: URL) throws -> RunningFixtureProcess {
        let process = Process()
        let outputDirectory = FileManager.default.temporaryDirectory
            .appending(path: "StoreFixtureProcess-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let outputURL = outputDirectory.appending(path: "stdout")
        let errorURL = outputDirectory.appending(path: "stderr")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let standardOutput = try FileHandle(forWritingTo: outputURL)
        let standardError = try FileHandle(forWritingTo: errorURL)
        process.executableURL = try fixtureGeneratorURL()
        process.arguments = [mode, storeURL.path]
        process.standardOutput = standardOutput
        process.standardError = standardError
        do {
            try process.run()
        } catch {
            try? standardOutput.close()
            try? standardError.close()
            try? FileManager.default.removeItem(at: outputDirectory)
            throw error
        }
        return RunningFixtureProcess(
            process: process,
            outputDirectory: outputDirectory,
            outputURL: outputURL,
            errorURL: errorURL,
            standardOutput: standardOutput,
            standardError: standardError
        )
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
        #expect(container.migrationPlan == nil)
        let context = ModelContext(container)
        try verifyTrackState(context)
        try verifyMirrorState(context, expected: mirrorState)
        try verifyMembershipState(context)
        try verifyLibraryState(context)
        try verifyRunState(context)
        try verifyFixPlanState(context)
    }

    private func verifyMembershipState(_ context: ModelContext) throws {
        let members = try context.fetch(FetchDescriptor<PersistedLibraryMember>())
        let member = try #require(members.first)
        #expect(members.count == 1)
        #expect(member.databaseID == "track-sentinel")
        #expect(member.isPresent)
        #expect(member.firstSeenRevisionValue == 0)
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
