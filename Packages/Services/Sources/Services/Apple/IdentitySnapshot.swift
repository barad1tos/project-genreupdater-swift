import Core
import Foundation

struct LibraryIdentitySnapshot: Equatable, Sendable {
    static let scriptName = "fetch_library_identity"
    static let columnSeparator: Character = "\u{1C}"
    static let itemSeparator: Character = "\u{1D}"

    let census: TrackIDCensus
    let rows: [LibraryIdentityRow]

    static func decode(_ output: String) throws -> Self {
        let response = output.trimmingCharacters(in: .whitespacesAndNewlines)
        try rejectProducerFailure(response)

        let fields = response.split(separator: columnSeparator, omittingEmptySubsequences: false)
        guard fields.count == 6,
              fields[0] == "IDENTITY",
              let declaredCount = Int(fields[1]),
              declaredCount >= 0,
              let generation = LibraryGeneration(sourceValue: String(fields[2]))
        else {
            throw parseError("Malformed identity snapshot response")
        }

        let rawIDs = try decodeColumn(fields[3], expectedCount: declaredCount, name: "database IDs")
        let artists = try decodeColumn(fields[4], expectedCount: declaredCount, name: "artists")
        let albumArtists = try decodeColumn(fields[5], expectedCount: declaredCount, name: "album artists")

        var rows = [LibraryIdentityRow]()
        rows.reserveCapacity(declaredCount)
        for index in 0 ..< declaredCount {
            let rawID = rawIDs[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard UInt64(rawID) != nil,
                  let databaseID = MusicDatabaseTrackID(rawValue: rawID)
            else {
                throw parseError("Identity snapshot contains an invalid database ID")
            }
            rows.append(LibraryIdentityRow(
                databaseID: databaseID,
                artist: observedText(artists[index]),
                albumArtist: observedText(albumArtists[index])
            ))
        }
        rows.sort { $0.databaseID.rawValue < $1.databaseID.rawValue }

        let census = try TrackIDCensus(
            ids: rows.map(\.databaseID),
            totalCount: declaredCount,
            generation: generation
        )
        return Self(census: census, rows: rows)
    }

    private static func decodeColumn(
        _ column: Substring,
        expectedCount: Int,
        name: String
    ) throws -> [String] {
        let values = expectedCount == 0
            ? []
            : column.split(separator: itemSeparator, omittingEmptySubsequences: false).map(String.init)
        guard values.count == expectedCount else {
            throw parseError("Identity snapshot \(name) column count does not match its declared count")
        }
        return values
    }

    private static func observedText(_ rawValue: String) -> Observed<String> {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.caseInsensitiveCompare("missing value") != .orderedSame else {
            return .absent
        }
        return .value(value)
    }

    private static func rejectProducerFailure(_ response: String) throws {
        if response == "RETRY:GENERATION" {
            throw AppleScriptBridgeError.libraryChanged(
                detail: "Music library generation changed during identity snapshot"
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
