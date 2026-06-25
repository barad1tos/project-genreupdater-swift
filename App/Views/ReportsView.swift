// ReportsView.swift — Container composing change log and charts from SwiftData.
//
// Uses @Query to fetch PersistedChangeLogEntry from SwiftData, converts to
// Core.ChangeLogEntry for the SharedUI presentation components.
// Change log is available on free tier; charts are gated behind .reportsCharts.

import AppKit
import Core
import Services
import SharedUI
import SwiftData
import SwiftUI

// MARK: - Reports View

/// Reports dashboard combining a change log table and summary charts.
///
/// Shows a full-screen EmptyStateView with "Go to Update" CTA when no entries
/// exist. Otherwise displays a VSplitView with change log (top) and feature-gated
/// charts (bottom). Undo callbacks are wired to UndoCoordinator via closures.
struct ReportsView: View {
    @Query(sort: \PersistedChangeLogEntry.timestamp, order: .reverse)
    private var persistedEntries: [PersistedChangeLogEntry]

    @Environment(AppDependencies.self) private var dependencies

    @State private var backupImportRequest: BackupCSVImportRequest?
    @State private var reportAlert: ReportsAlert?
    @State private var isImportingBackupCSV = false

    var body: some View {
        let entries = persistedEntries.map { $0.toChangeLogEntry() }

        Group {
            if entries.isEmpty {
                EmptyStateView(
                    icon: "chart.bar.doc.horizontal",
                    title: "Run your first scan to see library insights",
                    description: "Update your library to see genre distribution, year analytics, and change history.",
                    actionTitle: "Go to Update"
                ) {
                    NotificationCenter.default.post(name: .navigateToUpdate, object: nil)
                }
            } else {
                reportsContent(entries: entries)
            }
        }
        .navigationTitle("Reports")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                importBackupCSVButton
            }
        }
        .sheet(item: $backupImportRequest) { _ in
            BackupCSVImportSheet(isImporting: isImportingBackupCSV) { artist, album in
                Task {
                    await importBackupCSV(artist: artist, album: album)
                }
            }
        }
        .alert(item: $reportAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    // MARK: - Reports Content

    private func reportsContent(entries: [ChangeLogEntry]) -> some View {
        VSplitView {
            ReportsChangeLog(
                entries: entries,
                onUndoEntry: { entry in
                    Task {
                        await undoEntry(entry)
                    }
                },
                onUndoSession: { sessionEntries in
                    Task {
                        await undoSession(sessionEntries)
                    }
                }
            )
            .frame(minHeight: 200)

            FeatureGatedView(feature: .reportsCharts) {
                ReportsCharts(data: aggregateData(from: entries))
            }
            .frame(minHeight: 250)
        }
    }

    @MainActor
    private func undoEntry(_ entry: ChangeLogEntry) async {
        do {
            guard let undoCoordinator = dependencies.undoCoordinator else {
                throw BackupCSVImportError.servicesUnavailable
            }
            try await undoCoordinator.revertChange(entry)
        } catch {
            reportAlert = ReportsAlert(
                title: "Undo Failed",
                message: error.localizedDescription
            )
        }
    }

    @MainActor
    private func undoSession(_ entries: [ChangeLogEntry]) async {
        do {
            guard let undoCoordinator = dependencies.undoCoordinator else {
                throw BackupCSVImportError.servicesUnavailable
            }
            try await undoCoordinator.revertBatch(entries)
        } catch {
            reportAlert = ReportsAlert(
                title: "Undo Failed",
                message: error.localizedDescription
            )
        }
    }

    // MARK: - Backup Import Button

    private var importBackupCSVButton: some View {
        Button {
            backupImportRequest = BackupCSVImportRequest()
        } label: {
            Label("Import Revert CSV", systemImage: "arrow.uturn.backward")
        }
        .disabled(isImportingBackupCSV)
        .help("Import a backup CSV and restore years")
    }

    // MARK: - Backup CSV Import

    @MainActor
    private func importBackupCSV(
        artist: String,
        album: String?
    ) async {
        guard let url = chooseBackupCSVURL() else { return }

        isImportingBackupCSV = true
        defer { isImportingBackupCSV = false }

        do {
            guard let musicReader = dependencies.musicReader,
                  let undoCoordinator = dependencies.undoCoordinator else {
                throw BackupCSVImportError.servicesUnavailable
            }

            let csv = try String(contentsOf: url, encoding: .utf8)
            let tracks = try await musicReader.fetchAllTracks(
                artist: artist,
                ignoreTestFilter: true
            )
            let mappedTrackCount = try await dependencies.refreshTrackIDMappingOrThrow(
                musicKitTracks: tracks,
                scopedArtists: [artist],
                mergeExisting: true
            )
            guard mappedTrackCount > 0 || tracks.isEmpty else {
                throw BackupCSVImportError.noWritableTrackMapping
            }
            let result = try await undoCoordinator.revertYearsFromBackupCSV(
                csv,
                artist: artist,
                album: album,
                currentTracks: tracks
            )

            reportAlert = ReportsAlert(
                title: backupImportAlertTitle(for: result),
                message: backupImportMessage(for: result)
            )
        } catch {
            reportAlert = ReportsAlert(
                title: "Import Failed",
                message: error.localizedDescription
            )
        }
    }

    private func chooseBackupCSVURL() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Import Revert CSV"
        panel.prompt = "Import"

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    // MARK: - Data Aggregation

    /// Build chart summary data from change log entries.
    ///
    /// Groups entries by type and date to produce genre distribution, year
    /// distribution, and daily change counts for the charts view.
    private func aggregateData(from entries: [ChangeLogEntry]) -> ChartSummaryData {
        let genreEntries = entries.filter { $0.changeType == .genreUpdate }
        let yearEntries = entries.filter { $0.changeType == .yearUpdate || $0.changeType == .yearRevert }

        let genreDistribution = buildGenreDistribution(from: genreEntries)
        let yearDistribution = buildYearDistribution(from: entries)
        let changesOverTime = buildChangesOverTime(from: entries)

        return ChartSummaryData(
            totalProcessed: entries.count,
            genresUpdated: genreEntries.count,
            yearsUpdated: yearEntries.count,
            genreDistribution: genreDistribution,
            yearDistribution: yearDistribution,
            changesOverTime: changesOverTime
        )
    }

    /// Count occurrences of each new genre across genre update entries.
    private func buildGenreDistribution(
        from entries: [ChangeLogEntry]
    ) -> [ChartSummaryData.GenreCount] {
        var genreCounts: [String: Int] = [:]
        for entry in entries {
            if let genre = entry.newGenre, !genre.isEmpty {
                genreCounts[genre, default: 0] += 1
            }
        }
        return genreCounts.map { ChartSummaryData.GenreCount(genre: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    /// Count occurrences of each new year across year update entries.
    private func buildYearDistribution(
        from entries: [ChangeLogEntry]
    ) -> [ChartSummaryData.YearCount] {
        let yearEntries = entries.filter { $0.changeType == .yearUpdate }
        var yearCounts: [Int: Int] = [:]
        for entry in yearEntries {
            if let year = entry.newYear {
                yearCounts[year, default: 0] += 1
            }
        }
        return yearCounts.map { ChartSummaryData.YearCount(year: $0.key, count: $0.value) }
            .sorted { $0.year < $1.year }
    }

    /// Group entries by calendar day and count changes per day.
    private func buildChangesOverTime(
        from entries: [ChangeLogEntry]
    ) -> [ChartSummaryData.DayCount] {
        let calendar = Calendar.current
        var dayCounts: [Date: Int] = [:]

        for entry in entries {
            let dayStart = calendar.startOfDay(for: entry.timestamp)
            dayCounts[dayStart, default: 0] += 1
        }

        return dayCounts.map { ChartSummaryData.DayCount(date: $0.key, count: $0.value) }
            .sorted { $0.date < $1.date }
    }
}

private struct BackupCSVImportRequest: Identifiable {
    let id = UUID()
}

private struct ReportsAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

func backupImportAlertTitle(for result: YearBackupRevertResult) -> String {
    let completedCount = result.updatedCount + result.skippedCount
    let unresolvedCount = result.missingCount + result.failedCount

    guard unresolvedCount > 0 else {
        return "Revert Complete"
    }
    guard completedCount > 0 else {
        return "Revert Failed"
    }
    return "Revert Partial"
}

func backupImportMessage(for result: YearBackupRevertResult) -> String {
    var parts = [
        "Updated \(result.updatedCount) of \(result.parsedCount) CSV rows.",
    ]
    if result.skippedCount > 0 {
        parts.append("\(result.skippedCount) rows were already current and skipped.")
    }
    if result.missingCount > 0 {
        parts.append("\(result.missingCount) tracks were not found in Music.app.")
    }
    if result.failedCount > 0 {
        parts.append("\(result.failedCount) tracks failed write-safety checks or writes.")
        if let firstFailureDescription = result.firstFailureDescription {
            parts.append("First failure: \(firstFailureDescription).")
        }
    }
    return parts.joined(separator: " ")
}

private enum BackupCSVImportError: LocalizedError {
    case servicesUnavailable
    case noWritableTrackMapping

    var errorDescription: String? {
        switch self {
        case .servicesUnavailable:
            "Music library services are not ready yet"
        case .noWritableTrackMapping:
            "Imported tracks could not be matched to writable Music.app IDs"
        }
    }
}

private struct BackupCSVImportSheet: View {
    @Environment(\.dismiss) private var dismiss

    let isImporting: Bool
    let onImport: (String, String?) -> Void

    @State private var artist = ""
    @State private var album = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Import Revert CSV")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 10) {
                TextField("Artist", text: $artist)
                TextField("Album (optional)", text: $album)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Button {
                    submit()
                } label: {
                    Label("Choose CSV", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isImporting || normalizedArtist.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private var normalizedArtist: String {
        artist.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedAlbum: String? {
        album.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private func submit() {
        onImport(normalizedArtist, normalizedAlbum)
        dismiss()
    }
}
