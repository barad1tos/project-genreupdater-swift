import Foundation

extension UpdateRunReport {
    var plainTextSummary: String {
        var lines = [
            title,
            "Scope: \(scopeTitle)",
            "Tracks scanned: \(scannedTrackCount)",
            "Track changes: \(changedEntries.count)",
            "Tracks changed: \(changedTrackCount)",
            "Albums affected: \(affectedAlbumCount)",
            "Failures: \(failures.count)",
            "",
        ]

        appendOperationalNotes(to: &lines)
        appendDatabaseVerification(to: &lines)
        appendPendingVerificationDetails(to: &lines)
        appendOutcomeBreakdown(to: &lines)
        appendNoChangesSummary(to: &lines)
        appendFailures(to: &lines)
        appendChangeBreakdown(to: &lines)
        appendAlbumGroups(to: &lines)
        appendDetailedTrackResults(to: &lines)
        return lines.joined(separator: "\n")
    }

    private func appendOperationalNotes(to lines: inout [String]) {
        guard !operationalNotes.isEmpty else { return }

        lines.append("Run Health")
        lines.append(contentsOf: operationalNotes.map { "- \($0.title): \($0.detail)" })
        lines.append("")
    }

    private func appendDatabaseVerification(to lines: inout [String]) {
        guard let databaseVerification else { return }

        lines.append("Database Verification")
        if let error = databaseVerification.error {
            lines.append("- Skipped: \(error)")
        } else if databaseVerification.skippedDueToRecentVerification {
            lines.append("- Skipped after recent check: \(databaseVerification.verifiedTrackCount) tracks in store")
        } else {
            lines.append("- Verified tracks: \(databaseVerification.verifiedTrackCount)")
            lines.append("- Removed stale tracks: \(databaseVerification.removedCount)")
        }
        if !databaseVerification.removedTrackIDs.isEmpty {
            lines.append("- Removed IDs: \(databaseVerification.removedTrackIDs.joined(separator: ", "))")
        }
        lines.append("")
    }

    private func appendPendingVerificationDetails(to lines: inout [String]) {
        guard let pendingVerification,
              !pendingVerification.problematicDetails.isEmpty else { return }

        lines.append("Problematic Pending Albums")
        for detail in pendingVerification.problematicDetails {
            lines.append("- \(detail.artist) - \(detail.album): \(detail.reason), "
                + "\(detail.attemptCount) attempts, last checked \(detail.lastAttempt.reportDate)")
            lines.append("  Next verification: \(detail.nextVerification.reportDate); status: \(detail.status)")
            if let lastFailure = detail.lastFailure {
                lines.append("  Last failure: \(lastFailure)")
            }
        }
        lines.append("")
    }

    private func appendNoChangesSummary(to lines: inout [String]) {
        guard changedEntries.isEmpty, !operationalNotes.contains(where: { $0.id == "no-changes" }) else { return }

        lines.append("No changes were made during this run.")
        lines.append("")
    }

    private func appendFailures(to lines: inout [String]) {
        guard !failures.isEmpty else { return }

        lines.append("Needs Attention")
        for failure in failures {
            lines.append("- \(failure.title) (\(failure.subtitle)): \(failure.message)")
        }
        lines.append("")
    }

    private func appendChangeBreakdown(to lines: inout [String]) {
        guard !changeBreakdown.isEmpty else { return }

        lines.append("Change Breakdown")
        for item in changeBreakdown {
            lines.append("- \(item.changeType.displayLabel): \(item.summary)")
        }
        lines.append("")
    }

    private func appendAlbumGroups(to lines: inout [String]) {
        guard !albumGroups.isEmpty else { return }

        lines.append("Changed Albums")
        for group in albumGroups {
            lines.append("- \(group.title): \(group.changeType.displayLabel) \(group.changeSummary)")
            for entry in group.entries {
                lines.append("  - \(entry.trackName)")
            }
        }
    }

    private func appendDetailedTrackResults(to lines: inout [String]) {
        guard displayMode == .detailed else { return }

        let albumsWithDetails = albumResults.filter { album in
            album.tracks.contains { track in
                track.hasChanges || track.hasFailure
            }
        }
        guard !albumsWithDetails.isEmpty else { return }

        lines.append("")
        lines.append("Track Details")
        for album in albumsWithDetails {
            lines.append("- \(album.artist) - \(album.album)")
            for track in album.tracks where track.hasChanges || track.hasFailure {
                appendTrackDetail(track, to: &lines)
            }
        }
    }

    private func appendTrackDetail(_ track: UpdateRunTrackResult, to lines: inout [String]) {
        if track.hasChanges {
            lines.append("  - \(track.title): \(track.currentMetadataSummary); proposed \(track.proposedSummary)")
        }
        if let failureMessage = track.failureMessage {
            lines.append("  - \(track.title): failed \(failureMessage)")
        }
    }
}

extension Date {
    fileprivate var reportDate: String {
        formatted(date: .abbreviated, time: .shortened)
    }
}
