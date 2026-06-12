// ReportsChangeLog.swift — Session-grouped change log with sticky headers and hover undo.

import Core
import SwiftUI

// MARK: - Session Group

/// A cluster of change log entries within a single update session.
private struct SessionGroup: Identifiable {
    let id: Date
    let header: String
    let entries: [ChangeLogEntry]
}

// MARK: - Reports Change Log

/// Session-grouped change log with sticky headers, hover-only undo, and confirmation alerts.
///
/// Pure presentation component that accepts `[ChangeLogEntry]` from Core.
/// Undo actions are injected via callbacks — SharedUI does not import Services.
/// Entries are grouped by session (entries within 60-second gaps share a session).
public struct ReportsChangeLog: View {
    public let entries: [ChangeLogEntry]
    public let onUndoEntry: ((ChangeLogEntry) -> Void)?
    public let onUndoSession: (([ChangeLogEntry]) -> Void)?

    @State private var searchText = ""
    @State private var selectedChangeType: ChangeType?
    @State private var hoveredEntryID: UUID?
    @State private var showUndoConfirmation = false
    @State private var undoConfirmationEntry: ChangeLogEntry?
    @State private var undoConfirmationSession: SessionGroup?

    public init(
        entries: [ChangeLogEntry],
        onUndoEntry: ((ChangeLogEntry) -> Void)? = nil,
        onUndoSession: (([ChangeLogEntry]) -> Void)? = nil
    ) {
        self.entries = entries
        self.onUndoEntry = onUndoEntry
        self.onUndoSession = onUndoSession
    }

    public var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()

            if filteredEntries.isEmpty {
                if entries.isEmpty, searchText.isEmpty, selectedChangeType == nil {
                    // Global empty — ReportsView handles the full-screen CTA.
                    // Show a minimal spacer to avoid a blank void.
                    Spacer()
                } else {
                    EmptyStateView(
                        icon: "doc.text.magnifyingglass",
                        title: "No changes match the current filters",
                        description: "Try adjusting the search text or change type filter."
                    )
                }
            } else {
                sessionGroupedList
            }
        }
        .alert(
            undoAlertTitle,
            isPresented: $showUndoConfirmation
        ) {
            Button("Cancel", role: .cancel) {
                clearUndoState()
            }
            Button("Undo", role: .destructive) {
                performUndo()
            }
        } message: {
            Text(undoAlertMessage)
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Ayu.fgSecondary)

            TextField("Search tracks or artists...", text: $searchText)
                .textFieldStyle(.plain)

            changeTypePicker

            Text("\(filteredEntries.count) entries")
                .font(AppFont.caption)
                .foregroundStyle(Ayu.fgSecondary)
                .monospacedDigit()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
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

    // MARK: - Session-Grouped List

    private var sessionGroupedList: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(sessionGroups) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            changeLogRow(entry: entry)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            Divider()
                                .padding(.leading, Spacing.md)
                        }
                    } header: {
                        sessionHeader(group: group)
                    }
                }
            }
        }
    }

    // MARK: - Session Header

    private func sessionHeader(group: SessionGroup) -> some View {
        HStack {
            Text(group.header)
                .font(AppFont.caption)
                .foregroundStyle(Ayu.fgSecondary)

            Spacer()

            if onUndoSession != nil {
                Button {
                    undoConfirmationSession = group
                    showUndoConfirmation = true
                } label: {
                    Label("Undo Session", systemImage: "arrow.uturn.backward")
                        .font(AppFont.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Ayu.warning)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
        .background(Ayu.bgPrimary)
    }

    // MARK: - Change Log Row

    private func changeLogRow(entry: ChangeLogEntry) -> some View {
        HStack(spacing: Spacing.sm) {
            changeTypeLabel(for: entry.changeType)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.trackName)
                    .font(.body)
                    .lineLimit(1)
                Text(entry.artist)
                    .font(AppFont.caption)
                    .foregroundStyle(Ayu.fgSecondary)
                    .lineLimit(1)
            }

            Spacer()

            changeValueLabel(for: entry)

            if hoveredEntryID == entry.id, onUndoEntry != nil {
                Button {
                    undoConfirmationEntry = entry
                    showUndoConfirmation = true
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .foregroundStyle(Ayu.warning)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
        .background(
            hoveredEntryID == entry.id
                ? Ayu.bgTertiary.opacity(0.5)
                : Color.clear
        )
        .contentShape(.rect)
        .onHover { isHovered in
            withAnimation(Motion.curveFast) {
                hoveredEntryID = isHovered ? entry.id : nil
            }
        }
    }

    // MARK: - Cell Views

    private func changeTypeLabel(for changeType: ChangeType) -> some View {
        Image(systemName: changeType.iconName)
            .font(.body)
            .foregroundStyle(changeType.tintColor)
            .frame(width: 24)
            .accessibilityLabel(changeType.displayLabel)
    }

    private func changeValueLabel(for entry: ChangeLogEntry) -> some View {
        HStack(spacing: Spacing.xxs) {
            Text(oldValueText(for: entry))
                .foregroundStyle(Ayu.fgSecondary)
                .strikethrough()
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(Ayu.fgMuted)
            Text(newValueText(for: entry))
                .foregroundStyle(Ayu.fgPrimary)
                .bold()
        }
        .font(.callout)
        .lineLimit(1)
    }

    // MARK: - Filtering and Grouping

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

        return result.sorted { $0.timestamp > $1.timestamp }
    }

    private var sessionGroups: [SessionGroup] {
        groupBySession(filteredEntries)
    }

    // MARK: - Session Grouping

    private func groupBySession(_ sortedEntries: [ChangeLogEntry]) -> [SessionGroup] {
        guard !sortedEntries.isEmpty else { return [] }

        var groups: [SessionGroup] = []
        var currentEntries: [ChangeLogEntry] = []
        var sessionStart: Date?

        for entry in sortedEntries {
            if let start = sessionStart,
               abs(entry.timestamp.timeIntervalSince(start)) > 60 {
                let header = Self.formatSessionHeader(start: start, count: currentEntries.count)
                groups.append(SessionGroup(id: start, header: header, entries: currentEntries))
                currentEntries = [entry]
                sessionStart = entry.timestamp
            } else {
                currentEntries.append(entry)
                if sessionStart == nil { sessionStart = entry.timestamp }
            }
        }

        if let start = sessionStart, !currentEntries.isEmpty {
            let header = Self.formatSessionHeader(start: start, count: currentEntries.count)
            groups.append(SessionGroup(id: start, header: header, entries: currentEntries))
        }

        return groups
    }

    // MARK: - Undo Confirmation

    private var undoAlertTitle: String {
        if let entry = undoConfirmationEntry {
            return "Revert \(entry.changeType.displayLabel.lowercased()) change for \(entry.trackName)?"
        }
        if let session = undoConfirmationSession {
            return "Revert all \(session.entries.count) changes in this session?"
        }
        return "Confirm Undo"
    }

    private var undoAlertMessage: String {
        if undoConfirmationEntry != nil {
            return "This will restore the previous value."
        }
        if let session = undoConfirmationSession {
            return "All \(session.entries.count) changes from this session will be reverted."
        }
        return ""
    }

    private func performUndo() {
        if let entry = undoConfirmationEntry {
            onUndoEntry?(entry)
        } else if let session = undoConfirmationSession {
            onUndoSession?(session.entries)
        }
        clearUndoState()
    }

    private func clearUndoState() {
        undoConfirmationEntry = nil
        undoConfirmationSession = nil
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
            entry.oldArtist ?? "none"
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
            entry.newArtist ?? "none"
        }
    }

    // MARK: - Formatters

    private static let sessionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy '\u{2014}' HH:mm"
        return formatter
    }()

    private static func formatSessionHeader(start: Date, count: Int) -> String {
        let dateString = sessionDateFormatter.string(from: start)
        let noun = count == 1 ? "change" : "changes"
        return "\(dateString) (\(count) \(noun))"
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
        case .genreUpdate: Ayu.purple
        case .yearUpdate: Ayu.info
        case .trackCleaning: Ayu.accent
        case .albumCleaning: Ayu.success
        case .artistRename: Ayu.teal
        case .yearRevert: Ayu.error
        }
    }
}

// MARK: - Preview

#Preview("Change Log with Sessions") {
    ReportsChangeLog(
        entries: [
            ChangeLogEntry(
                id: UUID(),
                timestamp: .now.addingTimeInterval(-10),
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
                timestamp: .now.addingTimeInterval(-20),
                changeType: .yearUpdate,
                trackID: "2",
                artist: "Metallica",
                trackName: "Sad but True",
                albumName: "Metallica",
                oldYear: nil,
                newYear: 1991
            ),
            ChangeLogEntry(
                id: UUID(),
                timestamp: .now.addingTimeInterval(-3600),
                changeType: .genreUpdate,
                trackID: "3",
                artist: "Daft Punk",
                trackName: "Around the World",
                albumName: "Homework",
                oldGenre: "Pop",
                newGenre: "Electronic"
            ),
            ChangeLogEntry(
                id: UUID(),
                timestamp: .now.addingTimeInterval(-3620),
                changeType: .yearUpdate,
                trackID: "4",
                artist: "Daft Punk",
                trackName: "Da Funk",
                albumName: "Homework",
                oldYear: nil,
                newYear: 1997
            ),
        ],
        onUndoEntry: { _ in },
        onUndoSession: { _ in }
    )
    .frame(width: 700, height: 400)
}

#Preview("Change Log Empty") {
    ReportsChangeLog(entries: [])
        .frame(width: 700, height: 400)
}
