import Core
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
}

package enum StoreFixtureVerifier {
    package static func verifyV3Migration(at storeURL: URL) throws -> [V3MigrationEvidence] {
        var evidence: [V3MigrationEvidence] = []
        for _ in 0 ..< 2 {
            let container = try migratedContainer(at: storeURL)
            try evidence.append(V3MigrationEvidence(members: memberEvidence(in: ModelContext(container))))
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
            requiresFreshObservation: readiness == .incomplete(.freshObservationRequired)
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
}

package enum StoreFixtureVerificationError: LocalizedError {
    case missingEntity(String)

    package var errorDescription: String? {
        switch self {
        case let .missingEntity(entity):
            "The migrated V4 fixture has no \(entity) entity."
        }
    }
}
