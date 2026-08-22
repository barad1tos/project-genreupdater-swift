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
            metrics: makeMetrics(from: report),
            albums: report.albumResults.map(makeAlbum),
            notices: report.operationalNotes.map(makeNotice),
            contentAccess: .available,
            primaryActionLabel: "Start New Update",
            secondaryActionLabel: "Copy Report"
        )
    }

    private static func makeMetrics(from report: UpdateRunReport) -> [UpdateResultMetric] {
        [
            metric("scanned-tracks", "Scanned tracks", report.scannedTrackCount, .neutral),
            metric("changed-tracks", "Changed tracks", report.changedTrackCount, .success),
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
            changes: (track.changes + track.noOpChanges).map { change in
                makeChange(change, outcome: track.outcome)
            }
        )
    }

    private static func makeChange(
        _ change: UpdateRunChangeSummary,
        outcome: UpdateRunTrackOutcome
    ) -> UpdateResultChange {
        UpdateResultChange(
            id: change.id,
            type: makeType(change.changeType),
            oldValue: change.oldValue,
            newValue: change.newValue,
            state: makeChangeState(outcome)
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

    private static func makeChangeState(_ outcome: UpdateRunTrackOutcome) -> UpdateResultChangeState {
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
}
