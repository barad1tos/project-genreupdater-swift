import Core
import DesignUI
import Services
import Testing
@testable import Genre_Updater

@Suite("Verified write result adaptation")
struct UpdateResultWriteAdapterTests {
    @Test("maps verified outcomes without inferring writes")
    func mapsVerifiedOutcomes() {
        let report = makeReport()

        let snapshot = UpdateResultWriteAdapter.makeSnapshot(from: report)
        let metricValues = Dictionary(uniqueKeysWithValues: snapshot.metrics.map { ($0.id, $0.value) })
        let tracks = snapshot.albums.flatMap(\.tracks)
        let changes = tracks.flatMap(\.changes)

        #expect(snapshot.mode == .write)
        #expect(snapshot.status == .completedWithFailures)
        #expect(metricValues["changed-tracks"] == "1")
        #expect(metricValues["failed-tracks"] == "1")
        #expect(changes.contains { $0.state == .applied })
        #expect(changes.contains { $0.state == .noChange })
        #expect(tracks.contains { $0.id == "skipped" && $0.state == .skipped })
        #expect(tracks.contains { track in
            guard track.id == "failed" else { return false }
            if case .failed("Write denied") = track.state {
                return true
            }
            return false
        })
        #expect(tracks.contains { $0.id == "unchanged" && $0.state == .noChange })
    }

    @Test("preserves every operational note")
    func preservesOperationalNotes() {
        let snapshot = UpdateResultWriteAdapter.makeSnapshot(from: makeReport())

        #expect(snapshot.notices.map(\.id).contains("pending-verification"))
        #expect(snapshot.notices.map(\.id).contains("database-verification"))
        #expect(snapshot.notices.map(\.id).contains("recovery"))
    }

    @Test("report keeps applied no-op and unchanged outcomes distinct")
    func keepsReportOutcomesDistinct() throws {
        let report = makeReport()
        let tracks = try #require(report.albumResults.first?.tracks)
        let outcomes = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0.outcome) })

        #expect(outcomes["applied"] == .applied)
        #expect(outcomes["no-op"] == .noChange)
        #expect(outcomes["unchanged"] == .unchanged)
        #expect(report.albumResults.first?.changedTrackCount == 1)
    }

    private func makeReport() -> UpdateRunReport {
        var appliedEntry = ChangeLogEntry(
            changeType: .genreUpdate,
            trackID: "applied",
            artist: "Clutch",
            trackName: "Applied",
            albumName: "Pure Rock Fury"
        )
        appliedEntry.oldGenre = "Rock"
        appliedEntry.newGenre = "Stoner Rock"

        var noOpEntry = ChangeLogEntry(
            changeType: .yearUpdate,
            trackID: "no-op",
            artist: "Clutch",
            trackName: "No-op",
            albumName: "Pure Rock Fury"
        )
        noOpEntry.oldYear = 2001
        noOpEntry.newYear = 2001

        return UpdateRunReport(
            result: BatchUpdateResult(
                entries: [appliedEntry],
                noOpEntries: [noOpEntry],
                failedTrackIDs: ["failed"],
                errorDescriptions: ["Write denied"]
            ),
            completedEntries: [],
            trackStatuses: [
                "applied": .done,
                "no-op": .done,
                "skipped": .skipped,
                "failed": .failed("Write denied"),
                "unchanged": .done,
            ],
            tracks: [
                makeTrack(id: "applied", title: "Applied", position: 1),
                makeTrack(id: "no-op", title: "No-op", position: 2),
                makeTrack(id: "skipped", title: "Skipped", position: 3),
                makeTrack(id: "failed", title: "Failed", position: 4),
                makeTrack(id: "unchanged", title: "Unchanged", position: 5),
            ],
            testArtists: ["Clutch"],
            operationalContext: UpdateRunOperationalContext(
                pendingVerification: UpdateRunPendingVerificationSummary(total: 2, due: 1, problematic: 1),
                databaseVerification: UpdateRunDatabaseVerificationSummary(
                    verifiedTrackCount: 4,
                    removedTrackIDs: ["removed"]
                ),
                recovery: UpdateRunRecoverySummary(restoredCount: 1, skippedCount: 1, failedCount: 1)
            )
        )
    }

    private func makeTrack(id: String, title: String, position: Int) -> Track {
        Track(
            id: id,
            name: title,
            artist: "Clutch",
            album: "Pure Rock Fury",
            genre: "Rock",
            year: 2001,
            originalPosition: position
        )
    }
}
