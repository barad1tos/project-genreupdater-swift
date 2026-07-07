// UpdateDoneSection.swift -- Album-centered update run report.

import AppKit
import Core
import SharedUI
import SwiftUI

// MARK: - Update Done Section

struct UpdateDoneSection: View {
    @Bindable var viewModel: WorkflowViewModel
    let tracks: [Track]
    let testArtists: [String]
    let displayMode: ChangeDisplayMode

    @State private var selectedAlbumID: String?
    @State private var selectedFilter = UpdateRunAlbumFilter.all
    @State private var showsTechnicalDetails = false
    @State private var didCopyReport = false

    private var report: UpdateRunReport {
        UpdateRunReport(
            result: viewModel.result,
            completedEntries: viewModel.completedEntries,
            trackStatuses: viewModel.trackStatuses,
            tracks: tracks,
            testArtists: testArtists,
            displayMode: displayMode,
            operationalContext: UpdateRunOperationalContext(
                pendingVerification: viewModel.pendingVerificationReportSummary,
                databaseVerification: UpdateRunDatabaseVerificationSummary(
                    preflightResult: viewModel.maintenancePreflightResult
                ),
                recovery: viewModel.recoveryReportSummary
            )
        )
    }

    private var visibleAlbums: [UpdateRunAlbumResult] {
        selectedFilter.visibleAlbums(in: report.albumResults)
    }

    private var selectedAlbum: UpdateRunAlbumResult? {
        selectedFilter.selectedAlbum(in: report.albumResults, selectedAlbumID: selectedAlbumID)
    }

    var body: some View {
        VStack(spacing: 0) {
            UpdateRunStatusStrip(report: report)
            runHealthSection

            Divider()

            HStack(spacing: 0) {
                albumRail
                    .frame(width: 340)

                Divider()

                if let selectedAlbum {
                    UpdateRunAlbumDetailPane(
                        album: selectedAlbum,
                        showsTechnicalDetails: $showsTechnicalDetails
                    )
                } else {
                    emptyDetailPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            actionBar
        }
        .onAppear(perform: synchronizeSelection)
        .onChange(of: selectedFilter) { _, _ in
            synchronizeSelection()
        }
        .onChange(of: report.albumResults) { _, _ in
            synchronizeSelection()
        }
    }

    @ViewBuilder private var runHealthSection: some View {
        if report.hasOperationalNotes {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Run Health")
                    .font(AppFont.caption.weight(.semibold))
                    .foregroundStyle(Ayu.fgSecondary)

                VStack(spacing: Spacing.xs) {
                    ForEach(report.operationalNotes) { note in
                        UpdateRunHealthRow(note: note)
                    }
                }

                UpdateRunOperationalDetails(report: report)
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.md)
            .background(.regularMaterial)
        }
    }

    private var albumRail: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Picker("Filter", selection: $selectedFilter) {
                ForEach(UpdateRunAlbumFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                Text("\(visibleAlbums.count.formatted()) albums")
                    .font(AppFont.caption)
                    .foregroundStyle(Ayu.fgSecondary)
                Spacer()
                Text(report.scopeTitle)
                    .font(AppFont.caption)
                    .foregroundStyle(Ayu.accent)
                    .lineLimit(1)
            }

            ScrollView {
                LazyVStack(spacing: Spacing.xs) {
                    ForEach(visibleAlbums) { album in
                        UpdateRunAlbumRailRow(
                            album: album,
                            isSelected: album.id == selectedAlbum?.id
                        ) {
                            selectedAlbumID = album.id
                        }
                    }
                }
                .padding(.vertical, Spacing.xs)
            }
        }
        .padding(Spacing.md)
        .background(Ayu.bgSecondary.opacity(0.42))
    }

    private var emptyDetailPane: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(Ayu.success)
            Text("No album results")
                .font(AppFont.headline)
                .foregroundStyle(Ayu.fgPrimary)
            Text("The selected scope finished without changed or failed tracks.")
                .font(AppFont.caption)
                .foregroundStyle(Ayu.fgSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var actionBar: some View {
        HStack(spacing: Spacing.sm) {
            Text(actionBarHelp)
                .font(AppFont.caption)
                .foregroundStyle(Ayu.fgSecondary)
                .lineLimit(1)

            Spacer()

            Button {
                copyReportToPasteboard()
            } label: {
                Label(didCopyReport ? "Copied" : "Copy Report", systemImage: didCopyReport ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)

            Button {
                viewModel.reset()
            } label: {
                Label("Start New Update", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .tint(Ayu.accent)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
    }

    private var actionBarHelp: String {
        if report.hasFailures {
            return "Review failed tracks before another write run."
        }
        if report.changedEntries.isEmpty {
            return "Start another update when you are ready."
        }
        return "Review the changed album metadata or copy the audit report."
    }

    private func synchronizeSelection() {
        guard !visibleAlbums.isEmpty else {
            selectedAlbumID = nil
            return
        }
        if let selectedAlbumID, visibleAlbums.contains(where: { $0.id == selectedAlbumID }) {
            return
        }
        selectedAlbumID = visibleAlbums.first?.id
    }

    private func copyReportToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report.plainTextSummary, forType: .string)
        didCopyReport = true
    }
}

private struct UpdateRunHealthRow: View {
    let note: UpdateRunOperationalNote

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)

            Text(note.title)
                .font(AppFont.caption.weight(.semibold))
                .foregroundStyle(Ayu.fgPrimary)
                .lineLimit(1)

            Text(note.detail)
                .font(AppFont.caption)
                .foregroundStyle(Ayu.fgSecondary)
                .lineLimit(1)

            Spacer(minLength: Spacing.sm)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xxs)
        .background(tint.opacity(0.1), in: .rect(cornerRadius: Radius.sm))
    }

    private var iconName: String {
        switch note.severity {
        case .info:
            "info.circle"
        case .warning:
            "exclamationmark.triangle"
        case .failure:
            "xmark.octagon"
        }
    }

    private var tint: Color {
        switch note.severity {
        case .info:
            Ayu.info
        case .warning:
            Ayu.warning
        case .failure:
            Ayu.error
        }
    }
}

// MARK: - Status Strip

private struct UpdateRunStatusStrip: View {
    let report: UpdateRunReport

    var body: some View {
        HStack(spacing: Spacing.lg) {
            HStack(spacing: Spacing.md) {
                Image(systemName: statusIcon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 36, height: 36)
                    .background(statusColor.opacity(0.16), in: .circle)

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(report.title)
                        .font(AppFont.subheadline)
                        .foregroundStyle(Ayu.fgPrimary)
                        .lineLimit(1)
                    Text(summaryText)
                        .font(AppFont.caption)
                        .foregroundStyle(Ayu.fgSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Spacing.lg)

            HStack(spacing: Spacing.lg) {
                UpdateRunMetricCell(value: report.scannedTrackCount, label: "scanned", tint: Ayu.fgPrimary)
                UpdateRunMetricCell(value: report.changedEntries.count, label: "changes", tint: Ayu.success)
                UpdateRunMetricCell(value: report.changedTrackCount, label: "tracks changed", tint: Ayu.info)
                UpdateRunMetricCell(value: report.affectedAlbumCount, label: "albums", tint: Ayu.warning)
                UpdateRunMetricCell(value: report.failures.count, label: "failed", tint: failureMetricColor)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
        .background(.regularMaterial)
    }

    private var summaryText: String {
        "\(report.scopeTitle) - \(report.scannedTrackCount.formatted()) tracks scanned"
    }

    private var statusIcon: String {
        report.hasFailures ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    private var statusColor: Color {
        report.hasFailures ? Ayu.warning : Ayu.success
    }

    private var failureMetricColor: Color {
        report.hasFailures ? Ayu.error : Ayu.success
    }
}

private struct UpdateRunMetricCell: View {
    let value: Int
    let label: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted())
                .font(AppFont.metricSmall)
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(label)
                .font(AppFont.caption)
                .foregroundStyle(Ayu.fgSecondary)
                .lineLimit(1)
        }
        .frame(minWidth: 76, alignment: .leading)
    }
}

// MARK: - Album Rail

private struct UpdateRunAlbumRailRow: View {
    let album: UpdateRunAlbumResult
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: Spacing.sm) {
                UpdateRunAlbumArtwork(album: album, size: 42)

                VStack(alignment: .leading, spacing: 3) {
                    Text(album.album)
                        .font(AppFont.caption.weight(.semibold))
                        .foregroundStyle(Ayu.fgPrimary)
                        .lineLimit(1)
                    Text(album.artist)
                        .font(AppFont.caption)
                        .foregroundStyle(Ayu.fgSecondary)
                        .lineLimit(1)

                    HStack(spacing: Spacing.xs) {
                        UpdateRunStatusChip(text: "\(album.trackCount)", tint: Ayu.fgMuted)
                        if album.changedTrackCount > 0 {
                            UpdateRunStatusChip(text: "\(album.changedTrackCount) changed", tint: Ayu.success)
                        }
                        if album.failureCount > 0 {
                            UpdateRunStatusChip(text: "\(album.failureCount) failed", tint: Ayu.error)
                        }
                    }
                }

                Spacer(minLength: Spacing.xs)
            }
            .padding(Spacing.sm)
            .contentShape(Rectangle())
            .background(rowBackground, in: .rect(cornerRadius: Radius.sm))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.sm)
                    .strokeBorder(rowBorderColor, lineWidth: isSelected ? 1 : 0)
            }
        }
        .buttonStyle(.plain)
    }

    private var rowBackground: Color {
        isSelected ? Ayu.selection.opacity(0.34) : Ayu.bgPrimary.opacity(0.38)
    }

    private var rowBorderColor: Color {
        album.failureCount > 0 ? Ayu.error.opacity(0.42) : Ayu.accent.opacity(0.4)
    }
}

// MARK: - Album Detail

private struct UpdateRunAlbumDetailPane: View {
    let album: UpdateRunAlbumResult
    @Binding var showsTechnicalDetails: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            header

            UpdateRunTrackTable(tracks: album.tracks)
                .frame(maxHeight: .infinity)

            if hasTechnicalDetails {
                technicalDetails
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Spacing.lg) {
            UpdateRunAlbumArtwork(album: album, size: 132)

            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                    Text(album.album)
                        .font(AppFont.headline)
                        .foregroundStyle(Ayu.fgPrimary)
                        .lineLimit(1)
                    if album.needsReview {
                        UpdateRunStatusChip(text: "needs review", tint: Ayu.error)
                    }
                }

                Text(album.artist)
                    .font(AppFont.subheadline)
                    .foregroundStyle(Ayu.fgSecondary)
                    .lineLimit(1)

                HStack(spacing: Spacing.xs) {
                    UpdateRunStatusChip(text: "\(album.trackCount) tracks", tint: Ayu.fgMuted)
                    if let primaryGenre = album.primaryGenre {
                        UpdateRunStatusChip(text: primaryGenre, tint: Ayu.info)
                    }
                    if let yearSummary {
                        UpdateRunStatusChip(text: yearSummary, tint: Ayu.warning)
                    }
                }

                HStack(spacing: Spacing.sm) {
                    resultPill(
                        value: album.changedTrackCount,
                        label: "changed",
                        tint: album.changedTrackCount > 0 ? Ayu.success : Ayu.fgMuted
                    )
                    resultPill(
                        value: album.failureCount,
                        label: "failed",
                        tint: album.failureCount > 0 ? Ayu.error : Ayu.fgMuted
                    )
                    Text(album.primaryChangeSummary)
                        .font(AppFont.caption)
                        .foregroundStyle(Ayu.fgSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Spacing.md)
        }
        .padding(Spacing.md)
        .background(.regularMaterial, in: .rect(cornerRadius: Radius.md))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(Ayu.accent.opacity(0.18), lineWidth: 1)
        }
    }

    private var technicalDetails: some View {
        DisclosureGroup(isExpanded: $showsTechnicalDetails) {
            LazyVStack(alignment: .leading, spacing: Spacing.xxs) {
                ForEach(album.tracks) { track in
                    Text("\(track.title): \(track.technicalID)")
                        .font(.caption.monospaced())
                        .foregroundStyle(Ayu.fgMuted)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, Spacing.sm)
        } label: {
            Label("Technical details", systemImage: "wrench.and.screwdriver")
                .font(AppFont.caption)
                .foregroundStyle(Ayu.fgSecondary)
        }
        .padding(Spacing.sm)
        .background(Ayu.bgSecondary.opacity(0.72), in: .rect(cornerRadius: Radius.sm))
    }

    private var hasTechnicalDetails: Bool {
        !album.tracks.isEmpty
    }

    private var yearSummary: String? {
        if let changedYearSummary {
            return changedYearSummary
        }

        switch (album.currentYear, album.releaseYear) {
        case let (currentYear?, releaseYear?) where currentYear != releaseYear:
            return "\(currentYear) -> \(releaseYear)"
        case let (currentYear?, _):
            return "\(currentYear)"
        case let (_, releaseYear?):
            return "Release \(releaseYear)"
        default:
            return nil
        }
    }

    private var changedYearSummary: String? {
        let summaries = Set(album.tracks.flatMap(\.changes).compactMap { change -> String? in
            switch change.changeType {
            case .yearUpdate, .yearRevert:
                "Year \(change.summary)"
            case .genreUpdate, .trackCleaning, .albumCleaning, .artistRename:
                nil
            }
        })

        if summaries.count == 1 {
            return summaries.first
        }
        if summaries.count > 1 {
            return "\(summaries.count) year changes"
        }
        return nil
    }

    private func resultPill(value: Int, label: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(value.formatted())
                .font(AppFont.caption.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(AppFont.caption)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xxs)
        .background(tint.opacity(0.12), in: .capsule)
    }
}

// MARK: - Track Table

private struct UpdateRunTrackTable: View {
    let tracks: [UpdateRunTrackResult]

    var body: some View {
        VStack(spacing: 0) {
            headerRow

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tracks) { track in
                        UpdateRunTrackRow(track: track)
                        Divider()
                            .padding(.leading, Spacing.md)
                    }
                }
            }
        }
        .background(Ayu.bgSecondary.opacity(0.62), in: .rect(cornerRadius: Radius.md))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(Ayu.fgMuted.opacity(0.2), lineWidth: 1)
        }
    }

    private var headerRow: some View {
        HStack(spacing: Spacing.sm) {
            tableHeader("#", width: 34, alignment: .trailing)
            tableHeader("Track", minWidth: 180)
            tableHeader("Before run", width: 210)
            tableHeader("Result", width: 220)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Ayu.bgPrimary.opacity(0.36))
    }

    private func tableHeader(
        _ title: String,
        width: CGFloat? = nil,
        minWidth: CGFloat? = nil,
        alignment: Alignment = .leading
    ) -> some View {
        Text(title)
            .font(AppFont.caption.weight(.semibold))
            .foregroundStyle(Ayu.fgSecondary)
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
            .frame(minWidth: minWidth, maxWidth: minWidth == nil ? nil : .infinity, alignment: alignment)
    }
}

private struct UpdateRunTrackRow: View {
    let track: UpdateRunTrackResult

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Text(trackNumberText)
                .font(AppFont.caption.monospacedDigit())
                .foregroundStyle(Ayu.fgMuted)
                .frame(width: 34, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(AppFont.caption.weight(.semibold))
                    .foregroundStyle(Ayu.fgPrimary)
                    .lineLimit(1)
                if let trackStatus = track.trackStatus, !trackStatus.isEmpty {
                    Text(trackStatus)
                        .font(.caption2)
                        .foregroundStyle(Ayu.fgMuted)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)

            Text(track.currentMetadataSummary)
                .font(AppFont.caption)
                .foregroundStyle(Ayu.fgSecondary)
                .lineLimit(1)
                .frame(width: 210, alignment: .leading)

            HStack(alignment: .top, spacing: Spacing.xs) {
                UpdateRunStatusChip(text: resultLabel, tint: resultTint)
                Text(resultDetail)
                    .font(AppFont.caption)
                    .foregroundStyle(resultTint)
                    .lineLimit(track.hasFailure ? nil : 2)
            }
            .frame(width: 220, alignment: .leading)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .help(helpText)
    }

    private var trackNumberText: String {
        track.trackNumber.map(String.init) ?? "-"
    }

    private var resultLabel: String {
        if track.hasFailure {
            return "Failed"
        }
        if track.hasChanges {
            return "Changed"
        }
        guard let processingStatus = track.processingStatus else { return "Scanned" }
        return processingStatus.resultLabel
    }

    private var resultDetail: String {
        if let failureMessage = track.failureMessage {
            return failureMessage
        }
        if track.hasChanges {
            return track.proposedSummary
        }
        guard let processingStatus = track.processingStatus else {
            return "No metadata change"
        }
        return processingStatus.resultDetail
    }

    private var resultTint: Color {
        if track.hasFailure {
            return Ayu.error
        }
        if track.hasChanges {
            return Ayu.success
        }
        return track.processingStatus?.resultTint ?? Ayu.fgMuted
    }

    private var helpText: String {
        "\(track.title) - \(track.technicalID)"
    }
}

// MARK: - Shared Pieces

private struct UpdateRunAlbumArtwork: View {
    let album: UpdateRunAlbumResult
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(
                    LinearGradient(
                        colors: [Ayu.accent.opacity(0.55), Ayu.info.opacity(0.22), Ayu.bgTertiary],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(spacing: Spacing.xs) {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.24, weight: .semibold))
                Text(initials)
                    .font(.system(size: max(11, size * 0.15), weight: .bold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(Ayu.fgPrimary)
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(Ayu.fgPrimary.opacity(0.12), lineWidth: 1)
        }
        .accessibilityLabel("\(album.album) artwork")
    }

    private var initials: String {
        let words = album.album.split(separator: " ")
        let letters = words.prefix(2).compactMap(\.first)
        let value = letters.map(String.init).joined()
        return value.isEmpty ? "LP" : value.uppercased()
    }
}

private struct UpdateRunStatusChip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: .capsule)
    }
}

extension TrackProcessingStatus {
    fileprivate var resultLabel: String {
        switch self {
        case .queued:
            "Queued"
        case .analyzing:
            "Analyzed"
        case .writing:
            "Writing"
        case .done:
            "Scanned"
        case .failed:
            "Failed"
        case .skipped:
            "Skipped"
        }
    }

    fileprivate var resultDetail: String {
        switch self {
        case .queued:
            "Queued for processing"
        case .analyzing:
            "Metadata checked"
        case .writing:
            "Write in progress"
        case .done:
            "No metadata change"
        case let .failed(message):
            message
        case .skipped:
            "Skipped by workflow rules"
        }
    }

    fileprivate var resultTint: Color {
        switch self {
        case .failed:
            Ayu.error
        case .skipped, .queued:
            Ayu.fgMuted
        case .analyzing, .writing:
            Ayu.warning
        case .done:
            Ayu.fgSecondary
        }
    }
}
