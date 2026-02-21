import Foundation
import Testing
@testable import Core
@testable import Services

// MARK: - DryRunReport Tests

@Suite("DryRunReport — computed properties and aggregation")
struct DryRunReportTests {
    private func makeTrack(id: String = "T1") -> Track {
        Track(id: id, name: "Song", artist: "Artist", album: "Album")
    }

    private func makeChange(
        track: Track? = nil,
        changeType: ChangeType = .genreUpdate,
        confidence: Int = 80
    ) -> ProposedChange {
        ProposedChange(
            track: track ?? makeTrack(),
            changeType: changeType,
            oldValue: "old",
            newValue: "new",
            confidence: confidence,
            source: "Test"
        )
    }

    @Test("Empty report has zero counts")
    func emptyReport() {
        let report = DryRunReport(proposedChanges: [])
        #expect(report.totalChanges == 0)
        #expect(report.genreChanges == 0)
        #expect(report.yearChanges == 0)
        #expect(report.trackCleaningChanges == 0)
        #expect(report.albumCleaningChanges == 0)
        #expect(report.artistRenameChanges == 0)
        #expect(report.affectedTrackCount == 0)
        #expect(report.averageConfidence == 0)
        #expect(report.changesByType.isEmpty)
    }

    @Test("totalChanges counts all proposed changes")
    func totalChanges() {
        let changes = [
            makeChange(changeType: .genreUpdate),
            makeChange(changeType: .yearUpdate),
            makeChange(changeType: .trackCleaning),
        ]
        let report = DryRunReport(proposedChanges: changes)
        #expect(report.totalChanges == 3)
    }

    @Test("genreChanges counts only genreUpdate type")
    func genreChanges() {
        let changes = [
            makeChange(changeType: .genreUpdate),
            makeChange(changeType: .genreUpdate),
            makeChange(changeType: .yearUpdate),
        ]
        let report = DryRunReport(proposedChanges: changes)
        #expect(report.genreChanges == 2)
    }

    @Test("yearChanges counts yearUpdate and yearRevert")
    func yearChanges() {
        let changes = [
            makeChange(changeType: .yearUpdate),
            makeChange(changeType: .yearRevert),
            makeChange(changeType: .genreUpdate),
        ]
        let report = DryRunReport(proposedChanges: changes)
        #expect(report.yearChanges == 2)
    }

    @Test("trackCleaningChanges counts only trackCleaning type")
    func trackCleaningChanges() {
        let changes = [
            makeChange(changeType: .trackCleaning),
            makeChange(changeType: .albumCleaning),
        ]
        let report = DryRunReport(proposedChanges: changes)
        #expect(report.trackCleaningChanges == 1)
    }

    @Test("albumCleaningChanges counts only albumCleaning type")
    func albumCleaningChanges() {
        let changes = [
            makeChange(changeType: .albumCleaning),
            makeChange(changeType: .albumCleaning),
            makeChange(changeType: .genreUpdate),
        ]
        let report = DryRunReport(proposedChanges: changes)
        #expect(report.albumCleaningChanges == 2)
    }

    @Test("artistRenameChanges counts only artistRename type")
    func artistRenameChanges() {
        let changes = [
            makeChange(changeType: .artistRename),
        ]
        let report = DryRunReport(proposedChanges: changes)
        #expect(report.artistRenameChanges == 1)
    }

    @Test("affectedTrackCount counts unique track IDs")
    func affectedTrackCount() {
        let track1 = makeTrack(id: "T1")
        let track2 = makeTrack(id: "T2")
        let changes = [
            makeChange(track: track1, changeType: .genreUpdate),
            makeChange(track: track1, changeType: .yearUpdate),
            makeChange(track: track2, changeType: .genreUpdate),
        ]
        let report = DryRunReport(proposedChanges: changes)
        #expect(report.affectedTrackCount == 2)
    }

    @Test("averageConfidence computes integer average")
    func averageConfidence() {
        let changes = [
            makeChange(confidence: 80),
            makeChange(confidence: 60),
            makeChange(confidence: 100),
        ]
        let report = DryRunReport(proposedChanges: changes)
        #expect(report.averageConfidence == 80)
    }

    @Test("changesByType includes only types with at least one change")
    func changesByType() {
        let changes = [
            makeChange(changeType: .genreUpdate),
            makeChange(changeType: .genreUpdate),
            makeChange(changeType: .yearUpdate),
        ]
        let report = DryRunReport(proposedChanges: changes)
        let byType = report.changesByType
        // Only genreUpdate and yearUpdate should appear
        #expect(byType.count == 2)
        let genres = byType.first { $0.type == .genreUpdate }
        #expect(genres?.count == 2)
        let years = byType.first { $0.type == .yearUpdate }
        #expect(years?.count == 1)
    }
}
