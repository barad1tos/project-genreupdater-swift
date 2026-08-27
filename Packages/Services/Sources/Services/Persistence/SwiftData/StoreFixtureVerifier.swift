import Core
import Darwin
import Foundation
import SwiftData

package struct MemberMigrationEvidence: Codable, Sendable {
    package let databaseID: String
    package let isPresent: Bool
    package let firstSeenRevision: UInt64
    package let lastSeenFingerprint: String?
    package let removalRevision: UInt64?
    package let removedAt: Date?
}

package struct V3MigrationEvidence: Codable, Sendable {
    package let members: [MemberMigrationEvidence]
    package let usesAutomaticMigration: Bool
}

package struct MembershipMigrationEvidence: Codable, Sendable {
    package let members: [MemberMigrationEvidence]
    package let trackIDs: [String]
    package let historyEntryIDs: [UUID]
    package let certificateCount: Int
    package let usesAutomaticMigration: Bool
}

package struct ConcurrentOpenEvidence: Codable, Sendable {
    package let isBlocked: Bool
    package let isFinished: Bool
    package let openCount: Int
    package let hasOneContainer: Bool
    package let sameURLErrors: [String]
    package let canOpenOther: Bool
    package let otherURLOpenCount: Int
    package let otherURLErrors: [String]
}

package struct V4MigrationEvidence: Codable, Sendable {
    package let trackID: String
    package let appleScriptID: String?
    package let trackName: String
    package let artist: String
    package let historyTrackID: String
    package let linkedHistoryTrackID: String?
    package let members: [MemberMigrationEvidence]
    package let revision: UInt64
    package let presentIDs: [String]
    package let presentTrackIDs: [String]
    package let certificateCount: Int
    package let requiresFreshObservation: Bool
    package let usesAutomaticMigration: Bool
}

package enum StoreFixtureVerifier {
    package static func migrate(at storeURL: URL) throws {
        _ = try migratedContainer(at: storeURL)
    }

    package static func seedCertificate(at storeURL: URL) throws {
        let container = try migratedContainer(at: storeURL)
        let databaseID = try requireDatabaseID("track-sentinel")
        let membership = try MembershipFingerprint.make(ids: [databaseID])
        guard let certificateID = UUID(uuidString: "00000000-0000-0000-0000-000000000008") else {
            throw StoreFixtureVerificationError.missingEntity("certificate ID")
        }
        let certificate = ScopeCertificate(
            id: certificateID,
            revision: .initial,
            membership: membership,
            testArtists: [],
            fieldSet: .processingV1,
            evidence: ScopeEvidence(
                requestedFingerprint: membership.fingerprint,
                observedFingerprint: membership.fingerprint,
                trackCount: 1
            ),
            observedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let context = ModelContext(container)
        try context.insert(PersistedScopeCertificate(certificate: certificate))
        try context.save()
    }

    package static func verifyConcurrentOpen(at storeURL: URL) throws -> ConcurrentOpenEvidence {
        let lockURL = storeURL.appendingPathExtension("migration.lock")
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw StoreFixtureVerificationError.lockFailed(operation: "open", code: errno)
        }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw StoreFixtureVerificationError.lockFailed(operation: "acquire", code: errno)
        }

        let sameRecorder = FixtureOpenRecorder()
        let sameGroup = startOpeners(count: 2, at: storeURL, recorder: sameRecorder)
        let isBlocked = sameGroup.wait(timeout: .now() + 2) == .timedOut

        let otherURL = storeURL.deletingLastPathComponent().appending(path: "Other.store")
        let otherRecorder = FixtureOpenRecorder()
        let otherGroup = startOpeners(count: 1, at: otherURL, recorder: otherRecorder)
        let canOpenOther = otherGroup.wait(timeout: .now() + 10) == .success

        guard flock(descriptor, LOCK_UN) == 0 else {
            throw StoreFixtureVerificationError.lockFailed(operation: "release", code: errno)
        }
        let isFinished = sameGroup.wait(timeout: .now() + 30) == .success
        let sameResult = sameRecorder.result
        let otherResult = otherRecorder.result
        return ConcurrentOpenEvidence(
            isBlocked: isBlocked,
            isFinished: isFinished,
            openCount: sameResult.openCount,
            hasOneContainer: sameRecorder.hasOneContainer,
            sameURLErrors: sameResult.errors,
            canOpenOther: canOpenOther,
            otherURLOpenCount: otherResult.openCount,
            otherURLErrors: otherResult.errors
        )
    }

    package static func verifyV3Migration(at storeURL: URL) throws -> [V3MigrationEvidence] {
        var evidence: [V3MigrationEvidence] = []
        for _ in 0 ..< 2 {
            let container = try migratedContainer(at: storeURL)
            try evidence.append(V3MigrationEvidence(
                members: memberEvidence(in: ModelContext(container)),
                usesAutomaticMigration: container.migrationPlan == nil
            ))
        }
        return evidence
    }

    package static func verifyV2Migration(at storeURL: URL) throws -> [MembershipMigrationEvidence] {
        var evidence: [MembershipMigrationEvidence] = []
        for _ in 0 ..< 2 {
            let container = try migratedContainer(at: storeURL)
            let context = ModelContext(container)
            let trackIDs = try context.fetch(FetchDescriptor<PersistedTrack>()).map(\.trackID).sorted()
            let historyEntryIDs = try context.fetch(FetchDescriptor<PersistedChangeLogEntry>())
                .map(\.entryID)
                .sorted { $0.uuidString < $1.uuidString }
            let certificateCount = try context.fetchCount(FetchDescriptor<PersistedScopeCertificate>())
            try evidence.append(MembershipMigrationEvidence(
                members: memberEvidence(in: context),
                trackIDs: trackIDs,
                historyEntryIDs: historyEntryIDs,
                certificateCount: certificateCount,
                usesAutomaticMigration: container.migrationPlan == nil
            ))
        }
        return evidence
    }

    package static func verifyV4Migration(at storeURL: URL) async throws -> [V4MigrationEvidence] {
        var evidence: [V4MigrationEvidence] = []
        for _ in 0 ..< 2 {
            try await evidence.append(migrationEvidence(at: storeURL))
        }
        return evidence
    }

    private static func migrationEvidence(at storeURL: URL) async throws -> V4MigrationEvidence {
        let container = try migratedContainer(at: storeURL)
        let context = ModelContext(container)
        let track = try requireFirst(context.fetch(FetchDescriptor<PersistedTrack>()), entity: "track")
        let history = try requireFirst(
            context.fetch(FetchDescriptor<PersistedChangeLogEntry>()),
            entity: "history"
        )
        let members = try memberEvidence(in: context)

        let snapshot = try await TrackDataStore(modelContainer: container).loadMirrorSnapshot()
        let readiness = snapshot.readiness(
            for: MirrorRequirement(testArtists: [], fieldSet: .processingV1, maximumMetadataAge: nil),
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )

        return V4MigrationEvidence(
            trackID: track.trackID,
            appleScriptID: track.appleScriptID,
            trackName: track.name,
            artist: track.artist,
            historyTrackID: history.trackID,
            linkedHistoryTrackID: history.track?.trackID,
            members: members,
            revision: snapshot.revision.value,
            presentIDs: snapshot.presentIDs.map(\.rawValue).sorted(),
            presentTrackIDs: snapshot.presentTracks.map(\.id).sorted(),
            certificateCount: snapshot.certificates.count,
            requiresFreshObservation: readiness == .incomplete(.freshObservationRequired),
            usesAutomaticMigration: container.migrationPlan == nil
        )
    }

    private static func migratedContainer(at storeURL: URL) throws -> ModelContainer {
        let schema = ModelContainerFactory.makeSchema()
        let configuration = ModelConfiguration(
            "GenreUpdater",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        return try ModelContainerFactory.create(schema: schema, configuration: configuration)
    }

    private static func memberEvidence(in context: ModelContext) throws -> [MemberMigrationEvidence] {
        try context.fetch(FetchDescriptor<PersistedLibraryMember>())
            .map {
                MemberMigrationEvidence(
                    databaseID: $0.databaseID,
                    isPresent: $0.isPresent,
                    firstSeenRevision: $0.firstSeenRevisionValue,
                    lastSeenFingerprint: $0.lastSeenFingerprint,
                    removalRevision: $0.removalRevisionValue,
                    removedAt: $0.removedAt
                )
            }
            .sorted { $0.databaseID < $1.databaseID }
    }

    private static func requireFirst<Value>(_ values: [Value], entity: String) throws -> Value {
        guard let value = values.first else {
            throw StoreFixtureVerificationError.missingEntity(entity)
        }
        return value
    }

    private static func requireDatabaseID(_ value: String) throws -> MusicDatabaseTrackID {
        guard let databaseID = MusicDatabaseTrackID(rawValue: value) else {
            throw StoreFixtureVerificationError.missingEntity("database ID")
        }
        return databaseID
    }

    private static func startOpeners(
        count: Int,
        at storeURL: URL,
        recorder: FixtureOpenRecorder
    ) -> DispatchGroup {
        let group = DispatchGroup()
        for _ in 0 ..< count {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let container = try migratedContainer(at: storeURL)
                    recorder.recordOpen(container)
                } catch {
                    recorder.record(error)
                }
            }
        }
        return group
    }
}

private final class FixtureOpenRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var containers: [ModelContainer] = []
    private var errors: [String] = []

    var result: (openCount: Int, errors: [String]) {
        lock.withLock { (containers.count, errors) }
    }

    var hasOneContainer: Bool {
        lock.withLock {
            guard let first = containers.first else { return false }
            return containers.allSatisfy { $0 === first }
        }
    }

    func recordOpen(_ container: ModelContainer) {
        lock.withLock {
            containers.append(container)
        }
    }

    func record(_ error: any Error) {
        lock.withLock {
            errors.append(String(reflecting: error))
        }
    }
}

package enum StoreFixtureVerificationError: LocalizedError {
    case missingEntity(String)
    case lockFailed(operation: String, code: Int32)

    package var errorDescription: String? {
        switch self {
        case let .missingEntity(entity):
            "The migrated V4 fixture has no \(entity) entity."
        case let .lockFailed(operation, code):
            "Fixture store lock \(operation) failed: \(String(cString: strerror(code)))"
        }
    }
}
