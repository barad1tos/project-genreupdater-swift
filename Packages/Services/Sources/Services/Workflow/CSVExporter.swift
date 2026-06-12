// CSVExporter.swift — Exports change log entries as RFC 4180 CSV.

import Core
import Foundation

// MARK: - CSV Exporter

/// Generates RFC 4180-compliant CSV from change log entries.
///
/// Handles proper escaping of quotes, commas, and newlines in field values.
/// Dates are formatted as ISO 8601.
public enum CSVExporter {
    private static let header = "Date,Track,Artist,Album,Property,OldValue,NewValue"

    // Safety: Configured once at init, never mutated — concurrent reads are safe.
    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Export change log entries to a CSV string.
    ///
    /// - Parameter changes: The entries to export.
    /// - Returns: A complete CSV document including header row.
    public static func export(changes: [ChangeLogEntry]) -> String {
        var lines = [header]
        for entry in changes {
            lines.append(csvRow(for: entry))
        }
        return lines.joined(separator: "\r\n")
    }

    // MARK: - Row Building

    private static func csvRow(for entry: ChangeLogEntry) -> String {
        let dateString = iso8601.string(from: entry.timestamp)
        let (property, oldValue, newValue) = changeFields(for: entry)

        let fields = [
            dateString,
            entry.trackName,
            entry.artist,
            entry.albumName,
            property,
            oldValue,
            newValue,
        ]
        return fields.map { escapeCSVField($0) }.joined(separator: ",")
    }

    private static func changeFields(
        for entry: ChangeLogEntry
    ) -> (property: String, oldValue: String, newValue: String) {
        switch entry.changeType {
        case .genreUpdate:
            ("Genre", entry.oldGenre ?? "", entry.newGenre ?? "")
        case .yearUpdate:
            (
                "Year",
                entry.oldYear.map(String.init) ?? "",
                entry.newYear.map(String.init) ?? ""
            )
        case .yearRevert:
            (
                "Year Revert",
                entry.newYear.map(String.init) ?? "",
                entry.oldYear.map(String.init) ?? ""
            )
        case .trackCleaning:
            ("Track Name", entry.oldTrackName ?? "", entry.newTrackName ?? "")
        case .albumCleaning:
            ("Album Name", entry.oldAlbumName ?? "", entry.newAlbumName ?? "")
        case .artistRename:
            ("Artist", entry.oldArtist ?? "", entry.newArtist ?? "")
        }
    }

    // MARK: - CSV Escaping

    /// Escape a field value per RFC 4180.
    ///
    /// Fields containing commas, double quotes, or newlines are wrapped in
    /// double quotes. Internal double quotes are escaped by doubling them.
    private static func escapeCSVField(_ value: String) -> String {
        let needsQuoting = value.contains(",")
            || value.contains("\"")
            || value.contains("\n")
            || value.contains("\r")

        guard needsQuoting else { return value }

        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
