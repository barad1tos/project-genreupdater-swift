import Core
import Foundation

struct YearBackupRevertTarget: Equatable {
    let trackID: String?
    let trackName: String
    let albumName: String?
    let year: Int
}

enum YearBackupCSVParser {
    static func parse(
        _ csv: String,
        artist: String,
        album: String? = nil
    ) throws -> [YearBackupRevertTarget] {
        let rows = try parseCSV(csv)
        guard let header = rows.first else {
            throw UndoCoordinatorError.invalidBackupCSV(reason: "missing header")
        }

        let columnIndexes = buildColumnIndexes(from: header)
        guard columnIndexes["artist"] != nil else {
            throw UndoCoordinatorError.invalidBackupCSV(reason: "missing artist column")
        }
        guard hasAnyColumn(
            in: columnIndexes,
            names: ["year", "year_before_mgu", "old_year", "year_set_by_mgu", "new_year"]
        ) else {
            throw UndoCoordinatorError.invalidBackupCSV(reason: "missing year column")
        }

        return rows.dropFirst().compactMap { row in
            buildTarget(
                row: row,
                columnIndexes: columnIndexes,
                artist: artist,
                album: album
            )
        }
    }

    private static func buildTarget(
        row: [String],
        columnIndexes: [String: Int],
        artist: String,
        album: String?
    ) -> YearBackupRevertTarget? {
        let values = buildRowValues(row: row, columnIndexes: columnIndexes)
        let requestedArtist = normalizeText(artist)
        guard let rowArtist = values["artist"],
              rowArtist.localizedCaseInsensitiveCompare(requestedArtist) == .orderedSame else {
            return nil
        }

        let rowAlbum = values["album"] ?? values["album_name"] ?? ""
        let requestedAlbum = normalizeText(album ?? "").nilIfEmpty
        if let requestedAlbum,
           rowAlbum.localizedCaseInsensitiveCompare(requestedAlbum) != .orderedSame {
            return nil
        }

        guard let year = backupYear(from: values) else {
            return nil
        }

        return YearBackupRevertTarget(
            trackID: values["id"] ?? values["track_id"],
            trackName: values["name"] ?? values["track_name"] ?? "",
            albumName: rowAlbum.nilIfEmpty,
            year: year
        )
    }

    private static func parseCSV(_ csv: String) throws -> [[String]] {
        let normalizedCSV = csv
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isQuoted = false
        var index = normalizedCSV.startIndex

        while index < normalizedCSV.endIndex {
            let character = normalizedCSV[index]

            if isQuoted {
                index = consumeQuotedCharacter(
                    character,
                    in: normalizedCSV,
                    at: index,
                    field: &field,
                    isQuoted: &isQuoted
                )
                continue
            }

            switch character {
            case "\"":
                if field.isEmpty {
                    isQuoted = true
                } else {
                    field.append(character)
                }
            case ",":
                row.append(field)
                field = ""
            case "\n":
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            default:
                field.append(character)
            }
            index = normalizedCSV.index(after: index)
        }

        guard !isQuoted else {
            throw UndoCoordinatorError.invalidBackupCSV(reason: "unterminated quoted field")
        }

        if !field.isEmpty || !row.isEmpty || normalizedCSV.last == "," {
            row.append(field)
            rows.append(row)
        }

        return rows.filter { fields in
            fields.contains { !normalizeText($0).isEmpty }
        }
    }

    private static func consumeQuotedCharacter(
        _ character: Character,
        in csv: String,
        at index: String.Index,
        field: inout String,
        isQuoted: inout Bool
    ) -> String.Index {
        guard character == "\"" else {
            field.append(character)
            return csv.index(after: index)
        }

        let nextIndex = csv.index(after: index)
        if nextIndex < csv.endIndex,
           csv[nextIndex] == "\"" {
            field.append("\"")
            return csv.index(after: nextIndex)
        }

        isQuoted = false
        return nextIndex
    }

    private static func buildColumnIndexes(from header: [String]) -> [String: Int] {
        var indexes: [String: Int] = [:]
        for (index, column) in header.enumerated() {
            let normalized = normalizedColumnName(column)
            guard !normalized.isEmpty else { continue }
            indexes[normalized] = indexes[normalized] ?? index
        }
        return indexes
    }

    private static func buildRowValues(
        row: [String],
        columnIndexes: [String: Int]
    ) -> [String: String] {
        var values: [String: String] = [:]
        for (column, index) in columnIndexes where index < row.count {
            values[column] = normalizeText(row[index]).nilIfEmpty
        }
        return values
    }

    private static func hasAnyColumn(
        in columnIndexes: [String: Int],
        names: [String]
    ) -> Bool {
        names.contains { columnIndexes[$0] != nil }
    }

    private static func backupYear(from values: [String: String]) -> Int? {
        for column in ["year", "year_before_mgu", "old_year", "year_set_by_mgu", "new_year"] {
            if let value = values[column],
               let year = Int(value) {
                return year
            }
        }
        return nil
    }

    private static func normalizedColumnName(_ value: String) -> String {
        normalizeText(value)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
    }
}

struct YearBackupTrackMatcher {
    private let byID: [String: Track]
    private let byAlbumAndTrack: [String: Track]
    private let byName: [String: Track]

    init(currentTracks: [Track]) {
        var byID: [String: Track] = [:]
        var byAlbumAndTrack: [String: Track] = [:]
        var byName: [String: Track] = [:]

        for track in currentTracks {
            byID[track.id] = track
            byAlbumAndTrack[Self.lookupKey(track.album, track.name)] = track

            let normalizedName = Self.normalizeText(track.name).lowercased()
            byName[normalizedName] = byName[normalizedName] ?? track
        }

        self.byID = byID
        self.byAlbumAndTrack = byAlbumAndTrack
        self.byName = byName
    }

    func findTrack(for target: YearBackupRevertTarget) -> Track? {
        if let trackID = target.trackID,
           let track = byID[trackID] {
            return track
        }

        if let albumName = target.albumName,
           let track = byAlbumAndTrack[Self.lookupKey(albumName, target.trackName)] {
            return track
        }

        return byName[Self.normalizeText(target.trackName).lowercased()]
    }

    private static func lookupKey(_ albumName: String, _ trackName: String) -> String {
        "\(normalizeText(albumName).lowercased())\u{1F}\(normalizeText(trackName).lowercased())"
    }

    private static func normalizeText(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func normalizeText(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
}
