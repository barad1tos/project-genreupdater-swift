import Foundation
import Testing
@testable import Core
@testable import Services

// MARK: - CSVExporter Tests

@Suite("CSVExporter — RFC 4180 CSV generation")
struct CSVExporterTests {
    private func makeTrack(
        id: String = "T1",
        name: String = "Song",
        artist: String = "Artist",
        album: String = "Album"
    ) -> Track {
        Track(id: id, name: name, artist: artist, album: album)
    }

    private func makeEntry(
        changeType: ChangeType,
        trackName: String = "Song",
        artist: String = "Artist",
        albumName: String = "Album",
        oldGenre: String? = nil,
        newGenre: String? = nil,
        oldYear: Int? = nil,
        newYear: Int? = nil,
        oldTrackName: String? = nil,
        newTrackName: String? = nil,
        oldAlbumName: String? = nil,
        newAlbumName: String? = nil
    ) -> ChangeLogEntry {
        var entry = ChangeLogEntry(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            changeType: changeType,
            trackID: "T1",
            artist: artist,
            trackName: trackName,
            albumName: albumName
        )
        entry.oldGenre = oldGenre
        entry.newGenre = newGenre
        entry.oldYear = oldYear
        entry.newYear = newYear
        entry.oldTrackName = oldTrackName
        entry.newTrackName = newTrackName
        entry.oldAlbumName = oldAlbumName
        entry.newAlbumName = newAlbumName
        return entry
    }

    @Test("Empty changes produce header-only CSV")
    func emptyChanges() {
        let csv = CSVExporter.export(changes: [])
        #expect(csv == "Date,Track,Artist,Album,Property,OldValue,NewValue")
    }

    @Test("Genre update exports correctly")
    func genreUpdate() {
        let entry = makeEntry(
            changeType: .genreUpdate,
            oldGenre: "Rock",
            newGenre: "Metal"
        )
        let csv = CSVExporter.export(changes: [entry])
        let lines = csv.components(separatedBy: "\r\n")
        #expect(lines.count == 2)
        // Header
        #expect(lines[0] == "Date,Track,Artist,Album,Property,OldValue,NewValue")
        // Data row contains Genre property
        #expect(lines[1].contains("Genre"))
        #expect(lines[1].contains("Rock"))
        #expect(lines[1].contains("Metal"))
    }

    @Test("Year update exports correctly")
    func yearUpdate() {
        let entry = makeEntry(
            changeType: .yearUpdate,
            oldYear: 1969,
            newYear: 2020
        )
        let csv = CSVExporter.export(changes: [entry])
        let lines = csv.components(separatedBy: "\r\n")
        #expect(lines.count == 2)
        #expect(lines[1].contains("Year"))
        #expect(lines[1].contains("1969"))
        #expect(lines[1].contains("2020"))
    }

    @Test("Year revert exports with swapped old/new values")
    func yearRevert() {
        let entry = makeEntry(
            changeType: .yearRevert,
            oldYear: 1969,
            newYear: 2020
        )
        let csv = CSVExporter.export(changes: [entry])
        let lines = csv.components(separatedBy: "\r\n")
        #expect(lines[1].contains("Year Revert"))
        // For yearRevert, oldValue = newYear, newValue = oldYear (reverting)
        #expect(lines[1].contains("2020"))
        #expect(lines[1].contains("1969"))
    }

    @Test("Track cleaning exports correctly")
    func trackCleaning() {
        let entry = makeEntry(
            changeType: .trackCleaning,
            oldTrackName: "Song (Remastered)",
            newTrackName: "Song"
        )
        let csv = CSVExporter.export(changes: [entry])
        #expect(csv.contains("Track Name"))
        #expect(csv.contains("Song (Remastered)"))
    }

    @Test("Album cleaning exports correctly")
    func albumCleaning() {
        let entry = makeEntry(
            changeType: .albumCleaning,
            oldAlbumName: "Album [Deluxe]",
            newAlbumName: "Album"
        )
        let csv = CSVExporter.export(changes: [entry])
        #expect(csv.contains("Album Name"))
    }

    @Test("Artist rename exports correctly")
    func artistRename() {
        let entry = makeEntry(
            changeType: .artistRename,
            artist: "Iron Maiden"
        )
        let csv = CSVExporter.export(changes: [entry])
        #expect(csv.contains("Artist"))
        #expect(csv.contains("Iron Maiden"))
    }

    @Test("Fields with commas are quoted")
    func commasInFieldsAreQuoted() {
        let entry = makeEntry(
            changeType: .genreUpdate,
            trackName: "Song, Part 2",
            oldGenre: "Rock",
            newGenre: "Metal"
        )
        let csv = CSVExporter.export(changes: [entry])
        #expect(csv.contains("\"Song, Part 2\""))
    }

    @Test("Fields with double quotes are escaped by doubling")
    func quotesInFieldsAreEscaped() {
        let entry = makeEntry(
            changeType: .genreUpdate,
            artist: "The \"Best\" Band",
            oldGenre: "Rock",
            newGenre: "Metal"
        )
        let csv = CSVExporter.export(changes: [entry])
        #expect(csv.contains("\"The \"\"Best\"\" Band\""))
    }

    @Test("Multiple entries produce correct number of rows")
    func multipleEntries() {
        let entries = [
            makeEntry(changeType: .genreUpdate, oldGenre: "Rock", newGenre: "Metal"),
            makeEntry(changeType: .yearUpdate, oldYear: 2000, newYear: 2001),
            makeEntry(changeType: .trackCleaning, oldTrackName: "A", newTrackName: "B"),
        ]
        let csv = CSVExporter.export(changes: entries)
        let lines = csv.components(separatedBy: "\r\n")
        #expect(lines.count == 4) // 1 header + 3 data rows
    }

    @Test("Rows use CRLF line endings per RFC 4180")
    func crlfLineEndings() {
        let entry = makeEntry(changeType: .genreUpdate, oldGenre: "Rock", newGenre: "Metal")
        let csv = CSVExporter.export(changes: [entry])
        #expect(csv.contains("\r\n"))
        // Should not contain bare LF without CR
        let withoutCRLF = csv.replacingOccurrences(of: "\r\n", with: "")
        #expect(!withoutCRLF.contains("\n") || withoutCRLF.contains("\n") == false)
    }
}
