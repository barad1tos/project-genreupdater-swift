import Core
import Foundation

struct TrackWireError: Error, LocalizedError, Sendable, Equatable {
    let scriptName: String
    let detail: String

    var errorDescription: String? {
        "Failed to parse output from '\(scriptName)': \(detail)"
    }
}

enum TrackWireCodec {
    static let fieldSeparator: Character = "\u{1E}"
    static let recordSeparator: Character = "\u{1D}"

    static func decodeRecords(_ output: String, scriptName: String) throws -> [Core.Track] {
        var tracks: [Core.Track] = []
        for record in output.split(separator: recordSeparator, omittingEmptySubsequences: false) {
            let rawRecord = String(record)
            guard !rawRecord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            let fields = rawRecord.split(separator: fieldSeparator, omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.count == 12, let track = decodeTrack(fields) else {
                throw TrackWireError(
                    scriptName: scriptName,
                    detail: "Malformed track record: expected 12 fields, got \(fields.count)"
                )
            }
            tracks.append(track)
        }
        return tracks
    }

    private static func decodeTrack(_ fields: [String]) -> Core.Track? {
        guard fields.count >= 5,
              let databaseID = MusicDatabaseTrackID(rawValue: fields[0])
        else { return nil }

        return Core.Track(
            id: databaseID.rawValue,
            name: fields[1],
            artist: fields[2],
            album: fields[4],
            genre: optionalField(fields, at: 5),
            year: parseYear(optionalField(fields, at: 9)),
            dateAdded: optionalField(fields, at: 6).flatMap(parseDate),
            lastModified: optionalField(fields, at: 7).flatMap(parseDate),
            trackStatus: optionalField(fields, at: 8),
            releaseYear: parseReleaseYear(optionalField(fields, at: 10)),
            albumArtist: optionalField(fields, at: 3),
            appleScriptID: databaseID.rawValue
        )
    }

    private static func optionalField(_ fields: [String], at index: Int) -> String? {
        guard fields.indices.contains(index), !fields[index].isEmpty else { return nil }
        return fields[index]
    }

    static func parseYear(_ value: String?) -> Int? {
        value.flatMap(Int.init)
    }

    static func parseReleaseYear(_ value: String?) -> Int? {
        guard let value else { return nil }
        if let year = parseYear(value) {
            return year
        }
        guard let releaseDate = parseDate(value) else { return nil }
        return Calendar(identifier: .gregorian).component(.year, from: releaseDate)
    }

    static func parseDate(_ value: String) -> Date? {
        if let date = DateFormatters.compact.date(from: value) {
            return date
        }
        if let date = DateFormatters.iso8601.date(from: value) {
            return date
        }
        return DateFormatters.natural.date(from: value)
    }

    private enum DateFormatters {
        static let compact: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            return formatter
        }()

        /// Configured once at initialization and never mutated afterward.
        nonisolated(unsafe) static let iso8601 = ISO8601DateFormatter()

        static let natural: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm:ss a"
            formatter.locale = Locale(identifier: "en_US")
            return formatter
        }()
    }
}
