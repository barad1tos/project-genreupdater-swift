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

        let databaseIDs = try decodeColumn(fields[3], expectedCount: declaredCount, columnIndex: 0)
        let names = try decodeTextColumn(fields[4], expectedCount: declaredCount, columnIndex: 1)
        let artists = try decodeTextColumn(fields[5], expectedCount: declaredCount, columnIndex: 2)
        let albumArtists = try decodeTextColumn(fields[6], expectedCount: declaredCount, columnIndex: 3)
        let albums = try decodeTextColumn(fields[7], expectedCount: declaredCount, columnIndex: 4)
        let genres = try decodeTextColumn(fields[8], expectedCount: declaredCount, columnIndex: 5)
        let datesAdded = try decodeColumn(fields[9], expectedCount: declaredCount, columnIndex: 6)
        let modificationDates = try decodeColumn(fields[10], expectedCount: declaredCount, columnIndex: 7)
        let statuses = try decodeColumn(fields[11], expectedCount: declaredCount, columnIndex: 8)
        let years = try decodeColumn(fields[12], expectedCount: declaredCount, columnIndex: 9)
        let releaseDates = try decodeColumn(fields[13], expectedCount: declaredCount, columnIndex: 10)
        var tracks = [Core.Track]()
        var seenIDs = Set<MusicDatabaseTrackID>()
        tracks.reserveCapacity(declaredCount)

        for rowIndex in 0 ..< declaredCount {
            let databaseID = try decodeDatabaseID(databaseIDs[rowIndex])
            guard seenIDs.insert(databaseID).inserted else {
                throw parseError("Metadata snapshot contains a duplicate database ID")
            }
            let name = optionalText(names[rowIndex]) ?? ""
            let artist = optionalText(artists[rowIndex]) ?? ""
            let albumArtist = optionalText(albumArtists[rowIndex])
            let album = optionalText(albums[rowIndex]) ?? ""
            let genre = optionalText(genres[rowIndex])
            let dateAdded = optionalText(datesAdded[rowIndex]).flatMap(TrackWireCodec.parseDate)
            let lastModified = optionalText(modificationDates[rowIndex]).flatMap(TrackWireCodec.parseDate)
            let status = TrackWireCodec.parseStatus(optionalText(statuses[rowIndex]))
            let year = TrackWireCodec.parseYear(optionalText(years[rowIndex]))
            let releaseYear = TrackWireCodec.parseReleaseYear(optionalText(releaseDates[rowIndex]))

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

    private static func decodeTextColumn(
        _ column: Substring,
        expectedCount: Int,
        columnIndex: Int
    ) throws -> [String?] {
        do {
            let values = try JSONDecoder().decode([String?].self, from: Data(column.utf8))
            guard values.count == expectedCount else {
                throw parseError("Metadata column \(columnIndex + 1) count does not match its declared count")
            }
            return values
        } catch let error as AppleScriptBridgeError {
            throw error
        } catch {
            throw parseError("Metadata column \(columnIndex + 1) is not valid JSON text")
        }
    }

    private static func decodeDatabaseID(_ rawValue: String) throws -> MusicDatabaseTrackID {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UInt64(value) != nil, let databaseID = MusicDatabaseTrackID(rawValue: value) else {
            throw parseError("Metadata snapshot contains an invalid database ID")
        }
        return databaseID
    }

    private static func optionalText(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
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
