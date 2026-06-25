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

    init(
        pendingVerification: UpdateRunPendingVerificationSummary? = nil,
        databaseVerification: UpdateRunDatabaseVerificationSummary? = nil
    ) {
        self.pendingVerification = pendingVerification
        self.databaseVerification = databaseVerification
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
    let problematicDetails: [UpdateRunPendingVerificationDetail]

    init(
        total: Int,
        due: Int,
        problematic: Int,
        problematicDetails: [UpdateRunPendingVerificationDetail] = []
    ) {
        self.total = total
        self.due = due
        self.problematic = problematic
        self.problematicDetails = problematicDetails
    }
}
