import Core
import DesignUI
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Verified write result adaptation")
struct UpdateResultWriteAdapterTests {
    @Test("maps only tracks with explicit run evidence")
    func mapsVerifiedOutcomes() {
        let report = makeReport()

        let snapshot = UpdateResultWriteAdapter.makeSnapshot(from: report)
        let metricValues = Dictionary(uniqueKeysWithValues: snapshot.metrics.map { ($0.id, $0.value) })
        let tracks = snapshot.albums.flatMap(\.tracks)
        let changes = tracks.flatMap(\.changes)

        #expect(snapshot.mode == .write)
        #expect(snapshot.status == .completedWithFailures)
        #expect(!snapshot.canReview)
        #expect(metricValues["changed-tracks"] == "1")
        #expect(metricValues["applied-operations"] == "1")
        #expect(metricValues["no-op-operations"] == "1")
        #expect(metricValues["failed-tracks"] == "1")
        #expect(snapshot.primaryActionLabel == "Start New Update")
        #expect(snapshot.secondaryActionLabel == "Copy Report")
        #expect(snapshot.secondaryActionIcon == "doc.on.doc")
        #expect(changes.contains { $0.state == .applied })
        #expect(changes.contains { $0.state == .noChange })
        #expect(changes.allSatisfy { change in
            if case .proposed = change.state {
                return false
            }
            return true
        })
        #expect(Set(tracks.map { trackStateName($0.state) }) == ["applied", "no-change", "skipped", "failed"])
        #expect(Set(changes.map { changeStateName($0.state) }) == ["applied", "no-change"])
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

    @Test("skipped-only albums stay visible without evidence-free siblings")
    func keepsExactResultMembership() throws {
        let skipped = makeTrack(
            id: "skipped-only",
            title: "Green Machine",
            position: 1,
            artist: "Kyuss",
            album: "Blues for the Red Sun"
        )
        let sibling = makeTrack(
            id: "outside-run",
            title: "Thong Song",
            position: 2,
            artist: "Kyuss",
            album: "Blues for the Red Sun"
        )
        let report = UpdateRunReport(
            result: BatchUpdateResult(entries: [], failedTrackIDs: [], errorDescriptions: []),
            completedEntries: [],
            trackStatuses: [skipped.id: .skipped],
            tracks: [skipped, sibling],
            testArtists: ["Kyuss"]
        )

        let album = try #require(report.albumResults.first)

        #expect(report.albumResults.count == 1)
        #expect(album.title == "Kyuss - Blues for the Red Sun")
        #expect(album.tracks.map(\.id) == [skipped.id])
        #expect(album.tracks.first?.outcome == .skipped)
    }

    @Test("preserves every operational note")
    func preservesOperationalNotes() {
        let snapshot = UpdateResultWriteAdapter.makeSnapshot(from: makeReport())

        #expect(snapshot.notices.map(\.id).contains("pending-verification"))
        #expect(snapshot.notices.map(\.id).contains("database-verification"))
        #expect(snapshot.notices.map(\.id).contains("recovery"))
    }

    @Test("mixed track changes preserve each verified operation outcome")
    func preservesMixedChangeOutcomes() throws {
        let report = makeMixedReport(hasFailure: false)

        let track = try #require(UpdateResultWriteAdapter.makeSnapshot(from: report).albums.first?.tracks.first)

        #expect(track.state == .applied)
        #expect(track.changes.map(\.state) == [.applied, .noChange])
    }

    @Test("track failure does not recolor an applied operation")
    func keepsAppliedChangeTruth() throws {
        let report = makeMixedReport(hasFailure: true)

        let track = try #require(UpdateResultWriteAdapter.makeSnapshot(from: report).albums.first?.tracks.first)

        #expect(track.state == .failed(message: "Verification failed"))
        #expect(track.changes.map(\.state) == [.applied, .noChange])
    }

    @Test("missing-track changes and failure share one stable result row")
    func groupsMissingTrackEvidence() throws {
        let firstEntry = makeGenreEntry(trackID: "missing", newGenre: "Stoner Rock")
        var secondEntry = ChangeLogEntry(
            changeType: .yearUpdate,
            trackID: "missing",
            artist: "Clutch",
            trackName: "Missing",
            albumName: "Pure Rock Fury"
        )
        secondEntry.oldYear = 2000
        secondEntry.newYear = 2001
        let report = UpdateRunReport(
            result: BatchUpdateResult(
                entries: [firstEntry, secondEntry],
                failedTrackIDs: ["missing"],
                errorDescriptions: ["Write denied"]
            ),
            completedEntries: [],
            trackStatuses: ["missing": .failed("Write denied")],
            tracks: [],
            testArtists: ["Clutch"]
        )

        let rows = try #require(report.albumResults.first?.tracks)
        let row = try #require(rows.first)

        #expect(rows.count == 1)
        #expect(row.id == "missing")
        #expect(row.technicalID == "missing")
        #expect(row.changes.map(\.changeType) == [.genreUpdate, .yearUpdate])
        #expect(row.failureMessage == "Write denied")
        #expect(row.outcome == .failed(message: "Write denied"))
    }

    @Test("adapter preserves operational and technical details")
    func preservesResultDetails() throws {
        let snapshot = UpdateResultWriteAdapter.makeSnapshot(from: makeReport())
        let track = try #require(snapshot.albums.first?.tracks.first { $0.id == "applied" })
        let globalDetails = Dictionary(uniqueKeysWithValues: snapshot.details.map { ($0.id, $0.value) })
        let trackDetails = Dictionary(uniqueKeysWithValues: track.details.map { ($0.id, $0.value) })

        #expect(trackDetails["technical-id"] == "applied")
        #expect(trackDetails["track-number"] == "1")
        #expect(trackDetails["music-status"] == "subscription")
        #expect(trackDetails["processing-status"] == "Done")
        #expect(trackDetails["current-metadata"] == "Genre Rock")
        #expect(globalDetails["database-verified"] == "4 tracks")
        #expect(globalDetails["database-removed-count"] == "1 track")
        #expect(globalDetails["database-removed-id-0"] == "removed")
        #expect(globalDetails["pending-pending-album-reason"] == "no_year_found")
        #expect(globalDetails["pending-pending-album-attempts"] == "4")
        #expect(globalDetails["pending-pending-album-days"] == "14")
        #expect(globalDetails["pending-pending-album-status"] == "Needs review")
        #expect(globalDetails["pending-pending-album-last-failure"] == "No definitive year")
        #expect(globalDetails.keys.contains("pending-pending-album-first-attempt"))
        #expect(globalDetails.keys.contains("pending-pending-album-last-attempt"))
        #expect(globalDetails.keys.contains("pending-pending-album-next-verification"))
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
        let appliedEntry = makeGenreEntry(trackID: "applied", newGenre: "Stoner Rock")

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
                pendingVerification: makePendingSummary(),
                databaseVerification: UpdateRunDatabaseVerificationSummary(
                    verifiedTrackCount: 4,
                    removedTrackIDs: ["removed"]
                ),
                recovery: UpdateRunRecoverySummary(restoredCount: 1, skippedCount: 1, failedCount: 1)
            )
        )
    }

    private func makeMixedReport(hasFailure: Bool) -> UpdateRunReport {
        let appliedEntry = makeGenreEntry(trackID: "mixed", newGenre: "Stoner Rock")
        let noOpEntry = makeGenreEntry(trackID: "mixed", newGenre: "Rock")
        let failures = hasFailure ? ["mixed"] : []
        let messages = hasFailure ? ["Verification failed"] : []
        return UpdateRunReport(
            result: BatchUpdateResult(
                entries: [appliedEntry],
                noOpEntries: [noOpEntry],
                failedTrackIDs: failures,
                errorDescriptions: messages
            ),
            completedEntries: [],
            trackStatuses: ["mixed": hasFailure ? .failed("Verification failed") : .done],
            tracks: [makeTrack(id: "mixed", title: "Mixed", position: 1)],
            testArtists: ["Clutch"]
        )
    }

    private func makeGenreEntry(trackID: String, newGenre: String) -> ChangeLogEntry {
        var entry = ChangeLogEntry(
            changeType: .genreUpdate,
            trackID: trackID,
            artist: "Clutch",
            trackName: trackID.capitalized,
            albumName: "Pure Rock Fury"
        )
        entry.oldGenre = "Rock"
        entry.newGenre = newGenre
        return entry
    }

    private func makePendingSummary() -> UpdateRunPendingVerificationSummary {
        let lastAttempt = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = PendingAlbumEntry(
            id: "pending-album",
            artist: "Clutch",
            album: "Pure Rock Fury",
            reason: "no_year_found",
            retry: .init(attemptCount: 4, lastAttempt: lastAttempt, recheckInterval: 86400),
            metadata: ["last_failure": "No definitive year"]
        )
        let album = ProblematicPendingAlbum(
            entry: entry,
            totalAttempts: 4,
            firstAttempt: lastAttempt.addingTimeInterval(-14 * 86400),
            lastAttempt: lastAttempt,
            daysSinceFirstAttempt: 14,
            status: "Needs review"
        )
        return UpdateRunPendingVerificationSummary(
            total: 2,
            due: 1,
            problematic: 1,
            problematicDetails: [UpdateRunPendingVerificationDetail(album)]
        )
    }

    private func trackStateName(_ state: UpdateResultTrackState) -> String {
        switch state {
        case .ready: "ready"
        case .applied: "applied"
        case .noChange: "no-change"
        case .skipped: "skipped"
        case .failed: "failed"
        }
    }

    private func changeStateName(_ state: UpdateResultChangeState) -> String {
        switch state {
        case .proposed: "proposed"
        case .applied: "applied"
        case .noChange: "no-change"
        case .skipped: "skipped"
        case .failed: "failed"
        }
    }

    private func makeTrack(
        id: String,
        title: String,
        position: Int,
        artist: String = "Clutch",
        album: String = "Pure Rock Fury"
    ) -> Track {
        Track(
            id: id,
            name: title,
            artist: artist,
            album: album,
            genre: "Rock",
            year: 2001,
            trackStatus: "subscription",
            releaseYear: 2000,
            originalPosition: position
        )
    }
}
