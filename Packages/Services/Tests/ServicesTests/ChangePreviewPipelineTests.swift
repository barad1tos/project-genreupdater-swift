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

    @Test("Filter removes changes below minimum confidence")
    func filterByConfidence() {
        let changes = [
            makeChange(confidence: 90),
            makeChange(confidence: 50),
            makeChange(confidence: 70),
            makeChange(confidence: 30),
        ]
        let filtered = pipeline.filter(changes: changes, minConfidence: 60)
        #expect(filtered.count == 2)
        for change in filtered {
            #expect(change.confidence >= 60)
        }
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

    @Test("CSV export includes header and accepted rows only")
    func exportCSV() {
        let changes = [
            makeChange(confidence: 80, isAccepted: true),
            makeChange(confidence: 50, isAccepted: false),
        ]
        let csv = pipeline.exportCSV(changes)
        #expect(csv.hasSuffix("\n"))
        let lines = csv.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
        #expect(lines.count == 2) // header + 1 accepted row
        #expect(lines[0].hasPrefix("Track ID,"))
    }

    @Test("CSV export escapes commas and quotes")
    func exportCSVEscaping() {
        let track = makeTrack(artist: "AC/DC", album: "Back, In Black")
        let change = makeChange(
            track: track,
            oldValue: "Hard \"Rock\"",
            newValue: "Rock"
        )
        let csv = pipeline.exportCSV([change])
        let lines = csv.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
        #expect(lines.count == 2)
        #expect(lines[1].contains("\"Back, In Black\""))
    }

    @Test("CSV export with no accepted changes returns header only")
    func exportCSVEmpty() {
        let changes = [makeChange(isAccepted: false)]
        let csv = pipeline.exportCSV(changes)
        let lines = csv.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
        #expect(lines.count == 1) // header only
    }
}
