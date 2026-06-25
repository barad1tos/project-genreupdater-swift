import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Update run operational report")
struct UpdateRunOperationalReportTests {
    @Test("plain text summary includes problematic pending album details")
    func plainTextSummaryIncludesProblematicPendingAlbumDetails() throws {
        let detail = UpdateRunPendingVerificationDetail(makeProblematicAlbum())
        let report = makeReport(
            pendingVerification: UpdateRunPendingVerificationSummary(
                total: 4,
                due: 1,
                problematic: 1,
                problematicDetails: [detail]
            )
        )

        let note = try #require(report.operationalNotes.first { $0.id == "pending-verification" })
        #expect(note.detail == "4 pending, 1 due, 1 problematic.")
        #expect(note.severity == .warning)
        #expect(report.plainTextSummary.contains("Problematic Pending Albums"))
        #expect(report.plainTextSummary.contains("Clutch - Pure Rock Fury"))
        #expect(report.plainTextSummary.contains("no_year_found"))
        #expect(report.plainTextSummary.contains("3 attempts"))
        #expect(report.plainTextSummary.contains("Last failure: API timeout"))
    }

    @Test("plain text summary includes database verification details")
    func plainTextSummaryIncludesDatabaseVerificationDetails() throws {
        let report = makeReport(
            databaseVerification: UpdateRunDatabaseVerificationSummary(
                verifiedTrackCount: 151,
                removedTrackIDs: ["gone-1", "gone-2"]
            )
        )

        let note = try #require(report.operationalNotes.first { $0.id == "database-verification" })
        #expect(note.title == "Database Verification")
        #expect(note.detail == "151 verified, 2 removed.")
        #expect(note.severity == .warning)
        #expect(report.plainTextSummary.contains("Database Verification"))
        #expect(report.plainTextSummary.contains("- Verified tracks: 151"))
        #expect(report.plainTextSummary.contains("- Removed stale tracks: 2"))
        #expect(report.plainTextSummary.contains("- Removed IDs: gone-1, gone-2"))
    }

    @Test("database verification summary maps preflight skip and errors")
    func databaseVerificationSummaryMapsPreflightSkipAndErrors() throws {
        let skipped = UpdateRunDatabaseVerificationSummary(
            preflightResult: MaintenancePreflightResult(
                databaseVerification: DatabaseVerificationResult(
                    verifiedTrackCount: 42,
                    removedTrackIDs: [],
                    skippedDueToRecentVerification: true
                ),
                databaseVerificationError: nil,
                isPendingVerificationDue: false
            )
        )
        let failed = UpdateRunDatabaseVerificationSummary(
            preflightResult: MaintenancePreflightResult(
                databaseVerification: nil,
                databaseVerificationError: "Music.app did not return IDs",
                isPendingVerificationDue: false
            )
        )

        let skippedSummary = try #require(skipped)
        let failedSummary = try #require(failed)
        #expect(skippedSummary.skippedDueToRecentVerification)
        #expect(skippedSummary.verifiedTrackCount == 42)
        #expect(failedSummary.error == "Music.app did not return IDs")
    }

    @Test("problematic pending detail maps metadata failure and next verification")
    func problematicPendingDetailMapsMetadataFailureAndNextVerification() {
        let lastAttempt = Date(timeIntervalSince1970: 1000)
        let entry = PendingAlbumEntry(
            id: "artist-album",
            artist: "Artist",
            album: "Album",
            reason: "prerelease",
            attemptCount: 5,
            lastAttempt: lastAttempt,
            recheckInterval: 3600,
            metadata: ["last_error": "Still prerelease"]
        )
        let problematicAlbum = ProblematicPendingAlbum(
            entry: entry,
            totalAttempts: 5,
            firstAttempt: Date(timeIntervalSince1970: 100),
            lastAttempt: lastAttempt,
            daysSinceFirstAttempt: 7
        )

        let detail = UpdateRunPendingVerificationDetail(problematicAlbum)

        #expect(detail.id == "artist-album")
        #expect(detail.reason == "prerelease")
        #expect(detail.attemptCount == 5)
        #expect(detail.nextVerification == Date(timeIntervalSince1970: 4600))
        #expect(detail.lastFailure == "Still prerelease")
    }

    private func makeReport(
        pendingVerification: UpdateRunPendingVerificationSummary? = nil,
        databaseVerification: UpdateRunDatabaseVerificationSummary? = nil
    ) -> UpdateRunReport {
        UpdateRunReport(
            result: BatchUpdateResult(entries: [], failedTrackIDs: [], errorDescriptions: []),
            completedEntries: [],
            trackStatuses: [:],
            tracks: [],
            testArtists: [],
            operationalContext: UpdateRunOperationalContext(
                pendingVerification: pendingVerification,
                databaseVerification: databaseVerification
            )
        )
    }

    private func makeProblematicAlbum() -> ProblematicPendingAlbum {
        let lastAttempt = Date(timeIntervalSince1970: 86400)
        return ProblematicPendingAlbum(
            entry: PendingAlbumEntry(
                id: "clutch-pure-rock-fury",
                artist: "Clutch",
                album: "Pure Rock Fury",
                reason: "no_year_found",
                attemptCount: 3,
                lastAttempt: lastAttempt,
                recheckInterval: 86400,
                metadata: ["last_error": "API timeout"]
            ),
            totalAttempts: 3,
            firstAttempt: Date(timeIntervalSince1970: 0),
            lastAttempt: lastAttempt,
            daysSinceFirstAttempt: 2
        )
    }
}
