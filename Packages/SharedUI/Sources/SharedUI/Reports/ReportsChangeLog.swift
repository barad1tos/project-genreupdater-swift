// ReportsChangeLog.swift — Table-based change log with sorting, filtering, and search.

import Core
import SwiftUI

// MARK: - Reports Change Log

/// Sortable, filterable table of metadata changes applied to tracks.
///
/// Pure presentation component that accepts `[ChangeLogEntry]` from Core.
/// Supports column sorting, change type filtering via picker, and text search
/// across track name and artist fields. Shows `EmptyStateView` when no entries match.
public struct ReportsChangeLog: View {
    public let entries: [ChangeLogEntry]

    @State private var searchText = ""
    @State private var selectedChangeType: ChangeType?
    @State private var sortOrder: [KeyPathComparator<ChangeLogEntry>] = [
        .init(\.timestamp, order: .reverse),
    ]

    public init(entries: [ChangeLogEntry]) {
        self.entries = entries
    }

    public var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()

            if filteredEntries.isEmpty {
                EmptyStateView(
                    icon: "doc.text.magnifyingglass",
                    title: "No Changes Found",
                    description: searchText.isEmpty && selectedChangeType == nil
                        ? "No metadata changes have been recorded yet."
                        : "No changes match the current filters."
                )
            } else {
                changeLogTable
            }
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search tracks or artists...", text: $searchText)
                .textFieldStyle(.plain)

            changeTypePicker

            Text("\(filteredEntries.count) entries")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var changeTypePicker: some View {
        Picker("Change Type", selection: $selectedChangeType) {
            Text("All Types")
                .tag(ChangeType?.none)

            ForEach(ChangeType.allCases, id: \.rawValue) { changeType in
                Label(changeType.displayLabel, systemImage: changeType.iconName)
                    .tag(ChangeType?.some(changeType))
            }
        }
        .pickerStyle(.menu)
        .frame(width: 160)
    }

    // MARK: - Table

    private var changeLogTable: some View {
        Table(filteredEntries, sortOrder: $sortOrder) {
            TableColumn("Date", value: \.timestamp) { entry in
                Text(entry.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption)
                    .monospacedDigit()
            }
            .width(min: 120, ideal: 150)

            TableColumn("Track", value: \.trackName) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.trackName)
                        .font(.body)
                        .lineLimit(1)
                    Text(entry.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .width(min: 150, ideal: 220)

            TableColumn("Type") { entry in
                changeTypeLabel(for: entry.changeType)
            }
            .width(min: 80, ideal: 120)

            TableColumn("Change") { entry in
                changeValueLabel(for: entry)
            }
            .width(min: 140, ideal: 200)
        }
        .onChange(of: sortOrder) { _, _ in }
    }

    // MARK: - Cell Views

    private func changeTypeLabel(for changeType: ChangeType) -> some View {
        Label(changeType.displayLabel, systemImage: changeType.iconName)
            .font(.caption)
            .foregroundStyle(changeType.tintColor)
    }

    private func changeValueLabel(for entry: ChangeLogEntry) -> some View {
        HStack(spacing: 4) {
            Text(oldValueText(for: entry))
                .foregroundStyle(.secondary)
                .strikethrough()
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(newValueText(for: entry))
                .foregroundStyle(.primary)
                .bold()
        }
        .font(.callout)
        .lineLimit(1)
    }

    // MARK: - Filtering and Sorting

    private var filteredEntries: [ChangeLogEntry] {
        var result = entries

        if let selectedChangeType {
            result = result.filter { $0.changeType == selectedChangeType }
        }

        if !searchText.isEmpty {
            result = result.filter { entry in
                entry.trackName.localizedStandardContains(searchText)
                    || entry.artist.localizedStandardContains(searchText)
            }
        }

        return result.sorted(using: sortOrder)
    }

    // MARK: - Value Formatting

    private func oldValueText(for entry: ChangeLogEntry) -> String {
        switch entry.changeType {
        case .genreUpdate:
            entry.oldGenre ?? "none"
        case .yearUpdate, .yearRevert:
            entry.oldYear.map(String.init) ?? "none"
        case .trackCleaning:
            entry.oldTrackName ?? "none"
        case .albumCleaning:
            entry.oldAlbumName ?? "none"
        case .artistRename:
            entry.artist
        }
    }

    private func newValueText(for entry: ChangeLogEntry) -> String {
        switch entry.changeType {
        case .genreUpdate:
            entry.newGenre ?? "none"
        case .yearUpdate, .yearRevert:
            entry.newYear.map(String.init) ?? "none"
        case .trackCleaning:
            entry.newTrackName ?? "none"
        case .albumCleaning:
            entry.newAlbumName ?? "none"
        case .artistRename:
            entry.artist
        }
    }
}

// MARK: - ChangeType Display Helpers

extension ChangeType {
    public var displayLabel: String {
        switch self {
        case .genreUpdate: "Genre"
        case .yearUpdate: "Year"
        case .trackCleaning: "Track"
        case .albumCleaning: "Album"
        case .artistRename: "Artist"
        case .yearRevert: "Revert"
        }
    }

    public var iconName: String {
        switch self {
        case .genreUpdate: "tag.fill"
        case .yearUpdate: "calendar"
        case .trackCleaning: "music.note"
        case .albumCleaning: "opticaldisc"
        case .artistRename: "person.fill"
        case .yearRevert: "arrow.uturn.backward"
        }
    }

    public var tintColor: Color {
        switch self {
        case .genreUpdate: .purple
        case .yearUpdate: .blue
        case .trackCleaning: .orange
        case .albumCleaning: .green
        case .artistRename: .teal
        case .yearRevert: .red
        }
    }
}

// MARK: - Preview

#Preview("Change Log with Entries") {
    ReportsChangeLog(entries: [
        ChangeLogEntry(
            id: UUID(),
            timestamp: .now.addingTimeInterval(-3600),
            changeType: .genreUpdate,
            trackID: "1",
            artist: "Metallica",
            trackName: "Enter Sandman",
            albumName: "Metallica",
            oldGenre: "Rock",
            newGenre: "Metal"
        ),
        ChangeLogEntry(
            id: UUID(),
            timestamp: .now.addingTimeInterval(-7200),
            changeType: .yearUpdate,
            trackID: "2",
            artist: "Daft Punk",
            trackName: "Around the World",
            albumName: "Homework",
            oldYear: nil,
            newYear: 1997
        ),
    ])
    .frame(width: 700, height: 400)
}

#Preview("Change Log Empty") {
    ReportsChangeLog(entries: [])
        .frame(width: 700, height: 400)
}
