import Core
import Foundation
@preconcurrency import SwiftData

enum StoreSchemaV0: VersionedSchema {
    static let versionIdentifier = Schema.Version(0, 0, 0)

    /// The sandboxed store predates mirror provenance. Reuse the frozen V1
    /// entity definitions so their hashes remain identical while omitting the
    /// entity that was introduced in V1.
    static let models: [any PersistentModel.Type] = [
        StoreSchemaV1.PersistedTrack.self,
        StoreSchemaV1.PersistedChangeLogEntry.self,
        StoreSchemaV1.PersistedMetricsSnapshot.self,
        StoreSchemaV1.PersistedPendingAlbumEntry.self,
        StoreSchemaV1.PersistedPendingVerificationMetadata.self,
        StoreSchemaV1.PersistedRunRecord.self,
        StoreSchemaV1.PersistedRunWorkItem.self,
        StoreSchemaV1.PersistedRunReportItem.self,
        StoreSchemaV1.PersistedFixPlan.self,
        StoreSchemaV1.PersistedFixPlanDecision.self,
    ]
}

enum StoreSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static let models: [any PersistentModel.Type] = [
        PersistedTrack.self,
        PersistedMirrorState.self,
        PersistedChangeLogEntry.self,
        PersistedMetricsSnapshot.self,
        PersistedPendingAlbumEntry.self,
        PersistedPendingVerificationMetadata.self,
        PersistedRunRecord.self,
        PersistedRunWorkItem.self,
        PersistedRunReportItem.self,
        PersistedFixPlan.self,
        PersistedFixPlanDecision.self,
    ]

    @Model
    final class PersistedTrack {
        @Attribute(.unique) var trackID: String
        var appleScriptID: String?
        var name: String
        var artist: String
        var album: String
        var genre: String?
        var year: Int?
        var genreUpdated: Bool
        var yearUpdated: Bool
        var processedDate: Date?
        var lastError: String?
        var dateAdded: Date?
        var albumArtist: String?
        var trackStatus: String?
        var originalArtist: String?
        var originalAlbum: String?
        var yearBeforeMGU: Int?
        var yearSetByMGU: Int?
        var releaseYear: Int?

        @Relationship(deleteRule: .cascade, inverse: \PersistedChangeLogEntry.track)
        var changeLog: [PersistedChangeLogEntry] = []

        init(
            trackID: String,
            name: String,
            artist: String,
            album: String
        ) {
            self.trackID = trackID
            self.name = name
            self.artist = artist
            self.album = album
            genreUpdated = false
            yearUpdated = false
        }
    }

    @Model
    final class PersistedMirrorState {
        @Attribute(.unique) var key: String
        var scopeData: Data?

        init(key: String = "track-mirror", scopeData: Data? = nil) {
            self.key = key
            self.scopeData = scopeData
        }
    }

    @Model
    final class PersistedChangeLogEntry {
        @Attribute(.unique) var entryID: UUID
        var timestamp: Date
        var changeTypeRaw: String
        var trackID: String
        var artist: String
        var trackName: String
        var albumName: String
        var oldGenre: String?
        var newGenre: String?
        var oldYear: Int?
        var newYear: Int?
        var oldTrackName: String?
        var newTrackName: String?
        var oldAlbumName: String?
        var newAlbumName: String?
        var oldArtist: String?
        var newArtist: String?
        var oldAlbumArtist: String?
        var newAlbumArtist: String?
        var runID: UUID?
        var track: PersistedTrack?

        init(entryID: UUID, timestamp: Date, trackID: String, track: PersistedTrack? = nil) {
            self.entryID = entryID
            self.timestamp = timestamp
            changeTypeRaw = "genreUpdate"
            self.trackID = trackID
            artist = ""
            trackName = ""
            albumName = ""
            self.track = track
        }
    }

    @Model
    final class PersistedMetricsSnapshot {
        var totalTracks: Int
        var tracksWithGenre: Int
        var tracksWithYear: Int
        var tracksWithBoth: Int
        var tracksNeedingGenre: Int
        var tracksNeedingYear: Int
        var protectedFileCount: Int?
        var recentlyAdded: Int
        var timestamp: Date
        var previousTotalTracks: Int
        var previousTracksNeedingGenre: Int
        var previousTracksNeedingYear: Int
        var previousRecentlyAdded: Int

        init(totalTracks: Int, timestamp: Date) {
            self.totalTracks = totalTracks
            tracksWithGenre = 0
            tracksWithYear = 0
            tracksWithBoth = 0
            tracksNeedingGenre = 0
            tracksNeedingYear = 0
            recentlyAdded = 0
            self.timestamp = timestamp
            previousTotalTracks = 0
            previousTracksNeedingGenre = 0
            previousTracksNeedingYear = 0
            previousRecentlyAdded = 0
        }
    }

    @Model
    final class PersistedPendingAlbumEntry {
        @Attribute(.unique) var entryID: String
        var artist: String
        var album: String
        var reason: String
        var attemptCount: Int
        var lastAttempt: Date
        var recheckInterval: TimeInterval
        var metadataData: Data?

        init(entryID: String, timestamp: Date) {
            self.entryID = entryID
            artist = ""
            album = ""
            reason = ""
            attemptCount = 0
            lastAttempt = timestamp
            recheckInterval = 0
        }
    }

    @Model
    final class PersistedPendingVerificationMetadata {
        @Attribute(.unique) var metadataID: String
        var lastAutoVerification: Date?

        init(metadataID: String = "pending-verification", lastAutoVerification: Date? = nil) {
            self.metadataID = metadataID
            self.lastAutoVerification = lastAutoVerification
        }
    }

    @Model
    final class PersistedRunRecord {
        @Attribute(.unique) var runID: UUID
        var requestID: UUID
        var triggerRaw: String
        var intentRaw: String
        var stateRaw: String
        var writeAuthorityRaw: String?
        var recoveryID: UUID?
        var continuesRunID: UUID?
        var scopeData: Data
        var transitionsData: Data
        var syncNewCount: Int?
        var syncModifiedCount: Int?
        var syncIdentityChangedCount: Int?
        var syncRefreshedCount: Int?
        var syncRemovedCount: Int?
        var failureMessage: String?
        var startedAt: Date
        var finishedAt: Date?

        init(runID: UUID, data: Data, timestamp: Date) {
            self.runID = runID
            requestID = UUID()
            triggerRaw = "manualCheck"
            intentRaw = "check"
            stateRaw = "running"
            scopeData = data
            transitionsData = data
            startedAt = timestamp
        }
    }

    @Model
    final class PersistedRunWorkItem {
        @Attribute(.unique) var key: String
        var runID: UUID
        var itemID: UUID
        var position: Int
        var itemData: Data

        init(key: String, runID: UUID, itemID: UUID, position: Int, itemData: Data) {
            self.key = key
            self.runID = runID
            self.itemID = itemID
            self.position = position
            self.itemData = itemData
        }
    }

    @Model
    final class PersistedRunReportItem {
        @Attribute(.unique) var key: String
        var runID: UUID
        var itemID: UUID
        var position: Int
        var runStartedAt: Date
        var changeTypeRaw: String
        var stateRaw: String
        var artist: String
        var album: String
        var trackName: String
        var targetKindRaw: String?
        var itemData: Data

        init(key: String, runID: UUID, itemID: UUID, position: Int, timestamp: Date, data: Data) {
            self.key = key
            self.runID = runID
            self.itemID = itemID
            self.position = position
            runStartedAt = timestamp
            changeTypeRaw = "genreUpdate"
            stateRaw = "prepared"
            artist = ""
            album = ""
            trackName = ""
            itemData = data
        }
    }

    @Model
    final class PersistedFixPlan {
        #Unique<PersistedFixPlan>([\.planID, \.revision])

        var planID: UUID
        var revision: Int
        var sourceRunID: UUID
        var createdAt: Date
        var configSnapshotData: Data
        var scopeSnapshotData: Data
        var itemsData: Data
        var itemCount: Int
        var scopeSource: String
        var configFingerprint: String

        init(planID: UUID, sourceRunID: UUID, timestamp: Date, data: Data) {
            self.planID = planID
            revision = 1
            self.sourceRunID = sourceRunID
            createdAt = timestamp
            configSnapshotData = data
            scopeSnapshotData = data
            itemsData = data
            itemCount = 0
            scopeSource = "fullLibrary"
            configFingerprint = "fixture"
        }
    }

    @Model
    final class PersistedFixPlanDecision {
        @Attribute(.unique) var planID: UUID
        var planRevision: Int
        var decisionRevision: Int
        var decidedAt: Date
        var itemDecisionsData: Data

        init(planID: UUID, timestamp: Date, data: Data) {
            self.planID = planID
            planRevision = 1
            decisionRevision = 1
            decidedAt = timestamp
            itemDecisionsData = data
        }
    }
}

public enum StoreSchemaV2: VersionedSchema {
    public static let versionIdentifier = Schema.Version(2, 0, 0)

    public static let models: [any PersistentModel.Type] = [
        PersistedTrack.self,
        PersistedMirrorState.self,
        PersistedChangeLogEntry.self,
        PersistedMetricsSnapshot.self,
        PersistedPendingAlbumEntry.self,
        PersistedPendingVerificationMetadata.self,
        PersistedRunRecord.self,
        PersistedRunWorkItem.self,
        PersistedRunReportItem.self,
        PersistedFixPlan.self,
        PersistedFixPlanDecision.self,
    ]
}

enum StoreSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)

    static let models: [any PersistentModel.Type] = StoreSchemaV2.models + [
        PersistedLibraryMember.self,
    ]
}

enum StoreSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)

    static let models: [any PersistentModel.Type] = StoreSchemaV2.models + [
        PersistedLibraryMember.self,
    ]
}

enum StoreSchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)

    static let models: [any PersistentModel.Type] = [
        StoreSchemaV2.PersistedTrack.self,
        PersistedMirrorState.self,
        StoreSchemaV2.PersistedChangeLogEntry.self,
        StoreSchemaV2.PersistedMetricsSnapshot.self,
        StoreSchemaV2.PersistedPendingAlbumEntry.self,
        StoreSchemaV2.PersistedPendingVerificationMetadata.self,
        StoreSchemaV2.PersistedRunRecord.self,
        StoreSchemaV2.PersistedRunWorkItem.self,
        StoreSchemaV2.PersistedRunReportItem.self,
        StoreSchemaV2.PersistedFixPlan.self,
        StoreSchemaV2.PersistedFixPlanDecision.self,
        StoreSchemaV4.PersistedLibraryMember.self,
        PersistedScopeCertificate.self,
    ]
}

enum StoreMigrationPlan: SchemaMigrationPlan {
    static let schemas: [any VersionedSchema.Type] = [
        StoreSchemaV0.self,
        StoreSchemaV1.self,
        StoreSchemaV2.self,
        StoreSchemaV3.self,
        StoreSchemaV4.self,
        StoreSchemaV5.self,
    ]

    static let stages: [MigrationStage] = [
        .lightweight(fromVersion: StoreSchemaV0.self, toVersion: StoreSchemaV1.self),
        .lightweight(fromVersion: StoreSchemaV1.self, toVersion: StoreSchemaV2.self),
        .custom(
            fromVersion: StoreSchemaV2.self,
            toVersion: StoreSchemaV3.self,
            willMigrate: nil,
            didMigrate: migrateMembership
        ),
        .lightweight(fromVersion: StoreSchemaV3.self, toVersion: StoreSchemaV4.self),
        .custom(
            fromVersion: StoreSchemaV4.self,
            toVersion: StoreSchemaV5.self,
            willMigrate: nil,
            didMigrate: clearLegacyCoverage
        ),
    ]

    private static func migrateMembership(context: ModelContext) throws {
        let tracks = try context.fetch(FetchDescriptor<StoreSchemaV2.PersistedTrack>())
        let revision = try context.fetch(FetchDescriptor<StoreSchemaV2.PersistedMirrorState>())
            .first?
            .revisionValue ?? MirrorRevision.initial.value
        for track in tracks where track.appleScriptID == track.trackID {
            guard MusicDatabaseTrackID(rawValue: track.trackID) != nil else { continue }
            context.insert(StoreSchemaV3.PersistedLibraryMember(
                databaseID: track.trackID,
                isPresent: true,
                firstSeenRevisionValue: revision
            ))
        }
        try context.save()
    }

    private static func clearLegacyCoverage(context: ModelContext) throws {
        let certificates = try context.fetch(FetchDescriptor<StoreSchemaV5.PersistedScopeCertificate>())
        for certificate in certificates {
            context.delete(certificate)
        }
        try context.save()
    }
}
