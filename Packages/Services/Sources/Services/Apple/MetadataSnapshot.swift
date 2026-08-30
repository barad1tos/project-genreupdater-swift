import Core
import Foundation

struct LibraryMetadataSnapshot: Equatable, Sendable {
    static let scriptName = "fetch_scope_metadata"
    static let columnSeparator: Character = "\u{1C}"
    static let itemSeparator: Character = "\u{1D}"
    private static let columnCount = 11

    let generation: LibraryGeneration
    let tracks: [Core.Track]

    static func decode(_ output: String) throws -> Self {
        let response = output.trimmingCharacters(in: .whitespacesAndNewlines)
        try rejectProducerFailure(response)

        let fields = response.split(separator: columnSeparator, omittingEmptySubsequences: false)
        guard fields.count == 3 + columnCount,
              fields[0] == "METADATA",
              let declaredCount = Int(fields[1]),
              declaredCount >= 0,
              let generation = LibraryGeneration(sourceValue: String(fields[2]))
        else {
            throw parseError("Malformed metadata snapshot response")
        }

        let columns = try fields.dropFirst(3).enumerated().map { columnIndex, column in
            try decodeColumn(column, expectedCount: declaredCount, columnIndex: columnIndex)
        }
        var tracks = [Core.Track]()
        var seenIDs = Set<MusicDatabaseTrackID>()
        tracks.reserveCapacity(declaredCount)

        for rowIndex in 0 ..< declaredCount {
            let databaseID = try decodeDatabaseID(columns[0][rowIndex])
            guard seenIDs.insert(databaseID).inserted else {
                throw parseError("Metadata snapshot contains a duplicate database ID")
            }
            let name = columns[1][rowIndex]
            let artist = columns[2][rowIndex]
            let albumArtist = optionalText(columns[3][rowIndex])
            let album = optionalText(columns[4][rowIndex]) ?? ""
            let genre = optionalText(columns[5][rowIndex])
            let dateAdded = optionalText(columns[6][rowIndex]).flatMap(TrackWireCodec.parseDate)
            let lastModified = optionalText(columns[7][rowIndex]).flatMap(TrackWireCodec.parseDate)
            let status = optionalText(columns[8][rowIndex])
            let year = TrackWireCodec.parseYear(optionalText(columns[9][rowIndex]))
            let releaseYear = TrackWireCodec.parseReleaseYear(optionalText(columns[10][rowIndex]))

            tracks.append(Core.Track(
                id: databaseID.rawValue,
                name: name,
                artist: artist,
                album: album,
                genre: genre,
                year: year,
                dateAdded: dateAdded,
                lastModified: lastModified,
                trackStatus: status,
                releaseYear: releaseYear,
                albumArtist: albumArtist,
                appleScriptID: databaseID.rawValue
            ))
        }
        tracks.sort { ($0.databaseID?.rawValue ?? "") < ($1.databaseID?.rawValue ?? "") }
        return Self(generation: generation, tracks: tracks)
    }

    private static func decodeColumn(
        _ column: Substring,
        expectedCount: Int,
        columnIndex: Int
    ) throws -> [String] {
        let values = expectedCount == 0
            ? []
            : column.split(separator: itemSeparator, omittingEmptySubsequences: false).map(String.init)
        guard values.count == expectedCount else {
            throw parseError("Metadata column \(columnIndex + 1) count does not match its declared count")
        }
        return values
    }

    private static func decodeDatabaseID(_ rawValue: String) throws -> MusicDatabaseTrackID {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UInt64(value) != nil, let databaseID = MusicDatabaseTrackID(rawValue: value) else {
            throw parseError("Metadata snapshot contains an invalid database ID")
        }
        return databaseID
    }

    private static func optionalText(_ rawValue: String) -> String? {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.caseInsensitiveCompare("missing value") != .orderedSame else {
            return nil
        }
        return rawValue
    }

    private static func rejectProducerFailure(_ response: String) throws {
        if response == "RETRY:GENERATION" {
            throw AppleScriptBridgeError.libraryChanged(
                detail: "Music library generation changed during metadata snapshot"
            )
        }
        if response.hasPrefix("ERROR:LIBRARY_DB_NOT_FOUND:") {
            throw AppleScriptBridgeError.invalidLibraryPath
        }
        if response.lowercased().hasPrefix("error:") {
            throw AppleScriptBridgeError.executionFailed(
                scriptName: scriptName,
                detail: String(response.prefix(200))
            )
        }
    }

    private static func parseError(_ detail: String) -> AppleScriptBridgeError {
        .parseError(scriptName: scriptName, detail: detail)
    }
}
