import Foundation
import Testing
@testable import Core
@testable import Services

// MARK: - Helpers

private func makeTrack(
    id: String = "T1",
    artist: String = "Artist",
    album: String = "Album",
    name: String = "Track"
) -> Track {
    Track(id: id, name: name, artist: artist, album: album)
}

private func makeChange(
    track: Track? = nil,
    changeType: ChangeType = .genreUpdate,
    oldValue: String? = "Rock",
    newValue: String? = "Pop",
    confidence: Int = 80,
    source: String = "MusicBrainz",
    isAccepted: Bool = true
) -> ProposedChange {
    ProposedChange(
        track: track ?? makeTrack(),
        changeType: changeType,
        oldValue: oldValue,
        newValue: newValue,
        confidence: confidence,
        source: source,
        isAccepted: isAccepted
    )
}

// MARK: - Tests

@Suite("ChangePreviewPipeline — preview aggregation and filtering")
struct ChangePreviewPipelineTests {
    let pipeline = ChangePreviewPipeline()

    @Test("Filter removes year updates below minimum confidence")
    func filtersYearUpdates() {
        let changes = [
            makeChange(changeType: .yearUpdate, confidence: 90),
            makeChange(changeType: .yearUpdate, confidence: 50),
            makeChange(changeType: .yearUpdate, confidence: 70),
            makeChange(changeType: .yearUpdate, confidence: 30),
        ]
        let filtered = pipeline.filter(changes: changes, minConfidence: 60)
        #expect(filtered.count == 2)
        for change in filtered {
            #expect(change.confidence >= 60)
        }
    }

    @Test("Filter keeps a low-confidence correction when the track already has a year")
    func keepsExistingCorrection() {
        let existingYearTrack = Track(
            id: "existing-year",
            name: "Come Together",
            artist: "Beatles",
            album: "Abbey Road",
            year: 1969
        )
        let change = makeChange(
            track: existingYearTrack,
            changeType: .yearUpdate,
            oldValue: "1969",
            newValue: "1970",
            confidence: 30
        )

        let filtered = pipeline.filter(changes: [change], minConfidence: 60)

        #expect(filtered.map(\.id) == [change.id])
    }

    @Test("Filter preserves deterministic metadata changes below the year threshold")
    func preservesNonYearChanges() {
        let changes = [
            makeChange(changeType: .genreUpdate, confidence: 1),
            makeChange(changeType: .trackCleaning, confidence: 1),
            makeChange(changeType: .albumCleaning, confidence: 1),
            makeChange(changeType: .artistRename, confidence: 1),
            makeChange(changeType: .yearRevert, confidence: 1),
        ]

        let filtered = pipeline.filter(changes: changes, minConfidence: 100)

        #expect(filtered.map(\.changeType) == changes.map(\.changeType))
    }

    @Test("Filter with zero threshold returns all changes")
    func filterZeroThreshold() {
        let changes = [makeChange(confidence: 10), makeChange(confidence: 1)]
        let filtered = pipeline.filter(changes: changes, minConfidence: 0)
        #expect(filtered.count == 2)
    }

    @Test("Group by artist-album creates correct groups")
    func groupByArtistAlbum() {
        let trackA = makeTrack(id: "1", artist: "Beatles", album: "Abbey Road")
        let trackB = makeTrack(id: "2", artist: "Beatles", album: "Abbey Road")
        let trackC = makeTrack(id: "3", artist: "Pink Floyd", album: "DSOTM")

        let changes = [
            makeChange(track: trackA),
            makeChange(track: trackB),
            makeChange(track: trackC),
        ]

        let grouped = pipeline.groupByArtistAlbum(changes)
        #expect(grouped.count == 2)
        let beatlesGroup = grouped.first { $0.key.contains("Beatles") }
        #expect(beatlesGroup?.changes.count == 2)
    }

    @Test("Groups are sorted alphabetically by key")
    func groupsSortedAlphabetically() {
        let trackZ = makeTrack(artist: "Zeppelin", album: "IV")
        let trackA = makeTrack(artist: "ABBA", album: "Gold")
        let changes = [makeChange(track: trackZ), makeChange(track: trackA)]

        let grouped = pipeline.groupByArtistAlbum(changes)
        #expect(grouped.first?.key.contains("ABBA") == true)
        #expect(grouped.last?.key.contains("Zeppelin") == true)
    }

    @Test("Accept all sets all changes to accepted")
    func acceptAll() {
        var changes = [
            makeChange(isAccepted: false),
            makeChange(isAccepted: false),
        ]
        pipeline.acceptAll(&changes)
        for change in changes {
            #expect(change.isAccepted)
        }
    }

    @Test("Reject all sets all changes to rejected")
    func rejectAll() {
        var changes = [
            makeChange(isAccepted: true),
            makeChange(isAccepted: true),
        ]
        pipeline.rejectAll(&changes)
        for change in changes {
            #expect(!change.isAccepted)
        }
    }

    @Test("Toggle flips acceptance state")
    func toggle() {
        var change = makeChange(isAccepted: true)
        pipeline.toggle(&change)
        #expect(!change.isAccepted)
        pipeline.toggle(&change)
        #expect(change.isAccepted)
    }
}
