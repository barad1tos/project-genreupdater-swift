import Core
import DesignUI
import Foundation

enum UpdateResultWriteAdapter {
    static func makeSnapshot(from report: UpdateRunReport) -> UpdateResultSnapshot {
        UpdateResultSnapshot(
            mode: .write,
            status: report.hasFailures ? .completedWithFailures : .completed,
            title: report.title,
            subtitle: "\(report.scannedTrackCount.formatted()) tracks scanned",
            scope: report.scopeTitle,
            content: .init(
                metrics: makeMetrics(from: report),
                albums: report.albumResults.map(makeAlbum),
                notices: report.operationalNotes.map(makeNotice),
                contentAccess: .available,
                details: makeDetails(from: report)
            ),
            actions: .init(
                primaryLabel: "Start New Update",
                secondaryLabel: "Copy Report",
                secondaryIcon: "doc.on.doc"
            )
        )
    }

    private static func makeMetrics(from report: UpdateRunReport) -> [UpdateResultMetric] {
        [
            metric("scanned-tracks", "Scanned tracks", report.scannedTrackCount, .neutral),
            metric("changed-tracks", "Changed tracks", report.changedTrackCount, .success),
            metric("applied-operations", "Applied operations", report.changedEntries.count, .success),
            metric("no-op-operations", "No-op operations", report.noOpCount, .neutral),
            metric("affected-albums", "Affected albums", report.affectedAlbumCount, .info),
            metric("skipped-tracks", "Skipped tracks", report.skippedCount, .warning),
            metric("failed-tracks", "Failed tracks", Set(report.failures.map(\.technicalID)).count, .error),
        ]
    }

    private static func metric(
        _ id: String,
        _ label: String,
        _ value: Int,
        _ tone: Tone
    ) -> UpdateResultMetric {
        UpdateResultMetric(id: id, label: label, value: value.formatted(), tone: tone)
    }

    private static func makeAlbum(_ album: UpdateRunAlbumResult) -> UpdateResultAlbum {
        UpdateResultAlbum(
            id: album.id,
            title: album.title,
            tracks: album.tracks.map { track in
                makeTrack(track, artist: album.artist)
            }
        )
    }

    private static func makeTrack(_ track: UpdateRunTrackResult, artist: String) -> UpdateResultTrack {
        UpdateResultTrack(
            id: track.id,
            title: track.title,
            artist: artist,
            state: makeTrackState(track.outcome),
            changes: track.changes.map { makeChange($0, state: .applied) }
                + track.noOpChanges.map { makeChange($0, state: .noChange) },
            details: makeTrackDetails(track)
        )
    }

    private static func makeChange(
        _ change: UpdateRunChangeSummary,
        state: UpdateResultChangeState
    ) -> UpdateResultChange {
        UpdateResultChange(
            id: change.id,
            type: makeType(change.changeType),
            oldValue: change.oldValue,
            newValue: change.newValue,
            state: state
        )
    }

    private static func makeType(_ type: Core.ChangeType) -> DesignUI.ChangeType {
        switch type {
        case .genreUpdate: .genre
        case .yearUpdate: .year
        case .trackCleaning: .track
        case .albumCleaning: .album
        case .artistRename: .artist
        case .yearRevert: .revert
        }
    }

    private static func makeTrackState(_ outcome: UpdateRunTrackOutcome) -> UpdateResultTrackState {
        switch outcome {
        case let .failed(message): .failed(message: message)
        case .applied: .applied
        case .noChange, .unchanged: .noChange
        case .skipped: .skipped
        }
    }

    private static func makeNotice(_ note: UpdateRunOperationalNote) -> UpdateResultNotice {
        UpdateResultNotice(
            id: note.id,
            title: note.title,
            message: note.detail,
            tone: makeTone(note.severity)
        )
    }

    private static func makeTone(_ severity: UpdateRunOperationalNote.Severity) -> Tone {
        switch severity {
        case .info: .info
        case .warning: .warning
        case .failure: .error
        }
    }

    private static func makeTrackDetails(_ track: UpdateRunTrackResult) -> [UpdateResultDetail] {
        var details = [
            UpdateResultDetail(id: "technical-id", label: "Technical ID", value: track.technicalID),
            UpdateResultDetail(
                id: "current-metadata",
                label: "Current metadata",
                value: track.currentMetadataSummary
            ),
        ]
        if let trackNumber = track.trackNumber {
            details.append(UpdateResultDetail(
                id: "track-number",
                label: "Track number",
                value: trackNumber.formatted()
            ))
        }
        if let trackStatus = track.trackStatus, !trackStatus.isEmpty {
            details.append(UpdateResultDetail(id: "music-status", label: "Music status", value: trackStatus))
        }
        if let processingStatus = track.processingStatus {
            details.append(UpdateResultDetail(
                id: "processing-status",
                label: "Processing status",
                value: processingStatusLabel(processingStatus)
            ))
        }
        return details
    }

    private static func processingStatusLabel(_ status: TrackProcessingStatus) -> String {
        switch status {
        case .queued: "Queued"
        case .analyzing: "Analyzing"
        case .writing: "Writing"
        case .done: "Done"
        case .failed: "Failed"
        case .skipped: "Skipped"
        }
    }

    private static func makeDetails(from report: UpdateRunReport) -> [UpdateResultDetail] {
        var details = [UpdateResultDetail]()
        if let database = report.databaseVerification {
            details.append(contentsOf: makeDatabaseDetails(database))
        }
        if let pending = report.pendingVerification {
            details.append(contentsOf: pending.problematicDetails.flatMap(makePendingDetails))
        }
        return details
    }

    private static func makeDatabaseDetails(
        _ database: UpdateRunDatabaseVerificationSummary
    ) -> [UpdateResultDetail] {
        var details = [
            UpdateResultDetail(
                id: "database-status",
                label: "Database status",
                value: databaseStatus(database)
            ),
            UpdateResultDetail(
                id: "database-verified",
                label: "Database verified",
                value: "\(database.verifiedTrackCount.formatted()) \(trackNoun(database.verifiedTrackCount))"
            ),
            UpdateResultDetail(
                id: "database-removed-count",
                label: "Database removed",
                value: "\(database.removedCount.formatted()) \(trackNoun(database.removedCount))"
            ),
        ]
        details.append(contentsOf: database.removedTrackIDs.enumerated().map { index, trackID in
            UpdateResultDetail(
                id: "database-removed-id-\(index)",
                label: "Removed track ID",
                value: trackID
            )
        })
        return details
    }

    private static func databaseStatus(_ database: UpdateRunDatabaseVerificationSummary) -> String {
        if let error = database.error {
            return "Skipped: \(error)"
        }
        if database.skippedDueToRecentVerification {
            return "Skipped after a recent verification"
        }
        return "Completed"
    }

    private static func makePendingDetails(_ pending: UpdateRunPendingVerificationDetail) -> [UpdateResultDetail] {
        let prefix = "pending-\(pending.id)"
        var details = [
            UpdateResultDetail(
                id: "\(prefix)-album",
                label: "Problematic album",
                value: "\(pending.artist) - \(pending.album)"
            ),
            UpdateResultDetail(id: "\(prefix)-reason", label: "Reason", value: pending.reason),
            UpdateResultDetail(
                id: "\(prefix)-attempts",
                label: "Attempts",
                value: pending.attemptCount.formatted()
            ),
            UpdateResultDetail(
                id: "\(prefix)-first-attempt",
                label: "First attempt",
                value: pending.firstAttempt.updateRunReportDate
            ),
            UpdateResultDetail(
                id: "\(prefix)-last-attempt",
                label: "Last attempt",
                value: pending.lastAttempt.updateRunReportDate
            ),
            UpdateResultDetail(
                id: "\(prefix)-next-verification",
                label: "Next verification",
                value: pending.nextVerification.updateRunReportDate
            ),
            UpdateResultDetail(
                id: "\(prefix)-days",
                label: "Days pending",
                value: pending.daysSinceFirstAttempt.formatted()
            ),
            UpdateResultDetail(id: "\(prefix)-status", label: "Status", value: pending.status),
        ]
        if let lastFailure = pending.lastFailure {
            details.append(UpdateResultDetail(
                id: "\(prefix)-last-failure",
                label: "Last failure",
                value: lastFailure
            ))
        }
        return details
    }

    private static func trackNoun(_ count: Int) -> String {
        count == 1 ? "track" : "tracks"
    }
}
