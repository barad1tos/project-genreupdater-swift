import Core
import Foundation
import Services

struct UpdateRunOperationalNote: Identifiable, Equatable {
    enum Severity: Equatable { case info, warning, failure }

    let id: String
    let title: String
    let detail: String
    let severity: Severity
}

struct UpdateRunOperationalContext: Equatable {
    static let empty = Self()

    let pendingVerification: UpdateRunPendingVerificationSummary?
    let databaseVerification: UpdateRunDatabaseVerificationSummary?
    let recovery: UpdateRunRecoverySummary?

    init(
        pendingVerification: UpdateRunPendingVerificationSummary? = nil,
        databaseVerification: UpdateRunDatabaseVerificationSummary? = nil,
        recovery: UpdateRunRecoverySummary? = nil
    ) {
        self.pendingVerification = pendingVerification
        self.databaseVerification = databaseVerification
        self.recovery = recovery
    }
}

struct UpdateRunRecoverySummary: Equatable {
    let restoredCount: Int
    let skippedCount: Int
    let failedCount: Int

    init(restoredCount: Int = 0, skippedCount: Int = 0, failedCount: Int = 0) {
        self.restoredCount = restoredCount
        self.skippedCount = skippedCount
        self.failedCount = failedCount
    }

    init?(result: BatchUpdateResult) {
        let restored = result.entries.count
        let skipped = result.noOpEntries.count
        let failed = result.failedTrackIDs.count
        guard restored > 0 || skipped > 0 || failed > 0 else { return nil }
        self.init(restoredCount: restored, skippedCount: skipped, failedCount: failed)
    }
}

struct UpdateRunDatabaseVerificationSummary: Equatable {
    let verifiedTrackCount: Int
    let removedTrackIDs: [String]
    let skippedDueToRecentVerification: Bool
    let error: String?

    var removedCount: Int {
        removedTrackIDs.count
    }

    init(
        verifiedTrackCount: Int,
        removedTrackIDs: [String],
        skippedDueToRecentVerification: Bool = false,
        error: String? = nil
    ) {
        self.verifiedTrackCount = verifiedTrackCount
        self.removedTrackIDs = removedTrackIDs
        self.skippedDueToRecentVerification = skippedDueToRecentVerification
        self.error = error
    }

    init?(preflightResult: MaintenancePreflightResult?) {
        guard let preflightResult,
              preflightResult.databaseVerification != nil || preflightResult.databaseVerificationError != nil else {
            return nil
        }
        let result = preflightResult.databaseVerification
        self.init(
            verifiedTrackCount: result?.verifiedTrackCount ?? 0,
            removedTrackIDs: result?.removedTrackIDs ?? [],
            skippedDueToRecentVerification: result?.skippedDueToRecentVerification ?? false,
            error: preflightResult.databaseVerificationError
        )
    }
}

struct UpdateRunPendingVerificationDetail: Identifiable, Equatable {
    let id: String
    let artist: String
    let album: String
    let reason: String
    let attemptCount: Int
    let firstAttempt: Date
    let lastAttempt: Date
    let nextVerification: Date
    let daysSinceFirstAttempt: Int
    let status: String
    let lastFailure: String?

    init(_ album: ProblematicPendingAlbum) {
        let entry = album.entry
        id = album.id
        artist = entry.artist
        self.album = entry.album
        reason = entry.reason
        attemptCount = album.totalAttempts
        firstAttempt = album.firstAttempt
        lastAttempt = album.lastAttempt
        nextVerification = entry.lastAttempt.addingTimeInterval(entry.recheckInterval)
        daysSinceFirstAttempt = album.daysSinceFirstAttempt
        status = album.status
        lastFailure = Self.metadataFailure(entry.metadata)
    }

    private static func metadataFailure(_ metadata: [String: String]) -> String? {
        for key in ["last_failure", "last_error", "failure", "error"] {
            if let value = metadata[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

struct UpdateRunPendingVerificationSummary: Equatable {
    let total: Int
    let due: Int
    let problematic: Int
    let skippedByInterval: Int
    let verified: Int
    let problematicDetails: [UpdateRunPendingVerificationDetail]

    init(
        total: Int,
        due: Int,
        problematic: Int,
        skippedByInterval: Int = 0,
        verified: Int = 0,
        problematicDetails: [UpdateRunPendingVerificationDetail] = []
    ) {
        self.total = total
        self.due = due
        self.problematic = problematic
        self.skippedByInterval = skippedByInterval
        self.verified = verified
        self.problematicDetails = problematicDetails
    }
}

extension Date {
    var updateRunReportDate: String {
        formatted(date: .abbreviated, time: .shortened)
    }
}
