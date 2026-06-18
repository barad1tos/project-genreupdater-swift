// UpdateStreamingSection.swift -- progress-first update workflow status.

import Core
import SharedUI
import SwiftUI

// MARK: - Update Streaming Section

struct UpdateStreamingSection: View {
    @Bindable var viewModel: WorkflowViewModel
    let tracks: [Track]
    let testArtists: [String]

    @State private var showsDetails = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    progressCard
                    detailsDisclosure
                }
                .padding(Spacing.xl)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }

            Divider()
            actionBar
        }
    }

    // MARK: - Progress Card

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(progressTitle)
                        .font(AppFont.headline)
                        .foregroundStyle(Ayu.fgPrimary)

                    Text(progressSubtitle)
                        .font(AppFont.caption)
                        .foregroundStyle(Ayu.fgSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: Spacing.md)

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(processedCount.formatted()) / \(totalCount.formatted())")
                        .font(AppFont.metricSmall)
                        .monospacedDigit()
                        .foregroundStyle(Ayu.fgPrimary)
                        .contentTransition(.numericText())
                    Text("\(progressPercent)%")
                        .font(AppFont.caption)
                        .monospacedDigit()
                        .foregroundStyle(Ayu.fgSecondary)
                }
            }

            ProgressView(value: progressFraction)
                .progressViewStyle(.linear)
                .tint(Ayu.accent)

            currentTrackCard

            HStack(spacing: Spacing.sm) {
                progressPill(
                    "\(doneCount.formatted()) updated",
                    systemImage: "checkmark.circle.fill",
                    tint: Ayu.success
                )
                progressPill(
                    "\(failedCount.formatted()) failed",
                    systemImage: "xmark.circle.fill",
                    tint: failedCount > 0 ? Ayu.error : Ayu.fgMuted
                )
                if isTestArtistScopeActive {
                    progressPill(
                        testArtistScopeTitle,
                        systemImage: "person.crop.circle.badge.checkmark",
                        tint: Ayu.warning
                    )
                }

                Spacer(minLength: Spacing.sm)

                if let message = viewModel.progress?.message, !message.isEmpty {
                    Text(message)
                        .font(AppFont.caption)
                        .foregroundStyle(Ayu.fgSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(Spacing.lg)
        .background(Ayu.bgSecondary, in: .rect(cornerRadius: Radius.sm))
    }

    private var currentTrackCard: some View {
        HStack(spacing: Spacing.md) {
            statusIndicator(for: currentStatus)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(currentTrackTitle)
                    .font(AppFont.subheadline)
                    .foregroundStyle(Ayu.fgPrimary)
                    .lineLimit(1)
                Text(currentTrackSubtitle)
                    .font(AppFont.caption)
                    .foregroundStyle(Ayu.fgSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Spacing.md)

            statusLabel(for: currentStatus)
        }
        .padding(Spacing.md)
        .background(Ayu.bgTertiary, in: .rect(cornerRadius: Radius.sm))
        .help(currentTrackHelp)
    }

    // MARK: - Details

    private var detailsDisclosure: some View {
        DisclosureGroup(isExpanded: $showsDetails) {
            if showsDetails {
                LazyVStack(spacing: 1) {
                    ForEach(detailRows) { row in
                        ProgressTrackRow(row: row)
                    }
                }
                .padding(.top, Spacing.sm)
            }
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundStyle(Ayu.fgSecondary)
                Text("Activity details")
                    .font(AppFont.subheadline)
                    .foregroundStyle(Ayu.fgPrimary)
                Text("\(detailRows.count.formatted()) tracks")
                    .font(AppFont.caption)
                    .foregroundStyle(Ayu.fgSecondary)
            }
        }
        .padding(Spacing.md)
        .background(Ayu.bgSecondary, in: .rect(cornerRadius: Radius.sm))
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: Spacing.sm) {
            Text(cancelHelpText)
                .font(AppFont.caption)
                .foregroundStyle(Ayu.fgSecondary)
                .lineLimit(2)

            Spacer()

            if canPauseBatch {
                Button {
                    Task { await viewModel.pause() }
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(.bordered)
            }

            Button(role: .cancel) {
                viewModel.cancel()
            } label: {
                Label("Cancel Run", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
        }
        .padding(Spacing.md)
    }

    // MARK: - Derived State

    private var processedCount: Int {
        viewModel.progress?.current ?? viewModel.processedCount
    }

    private var totalCount: Int {
        let progressTotal = viewModel.progress?.total ?? viewModel.totalCount
        return max(progressTotal, tracks.count)
    }

    private var progressFraction: Double {
        guard totalCount > 0 else { return 0 }
        return min(max(Double(processedCount) / Double(totalCount), 0), 1)
    }

    private var progressPercent: Int {
        Int((progressFraction * 100).rounded())
    }

    private var progressTitle: String {
        switch viewModel.phase {
        case .applying:
            "Writing accepted changes"
        case .scanning where viewModel.mode == .fullLibrary && !viewModel.previewOnly:
            "Updating Music.app"
        case .scanning:
            "Building update preview"
        default:
            "Processing update"
        }
    }

    private var canPauseBatch: Bool {
        guard viewModel.mode == .fullLibrary, case .scanning = viewModel.phase else {
            return false
        }
        return true
    }

    private var progressSubtitle: String {
        if isTestArtistScopeActive {
            return "Pipeline is limited to configured test artists."
        }
        return viewModel.previewOnly ? "No changes are written in preview mode." : "Live writes are enabled."
    }

    private var currentTrack: Track? {
        if let currentTrackID = viewModel.currentTrackID,
           let track = tracks.first(where: { $0.id == currentTrackID }) {
            return track
        }

        let index = processedCount > 0 ? processedCount - 1 : 0
        guard tracks.indices.contains(index) else { return nil }
        return tracks[index]
    }

    private var currentStatus: TrackProcessingStatus {
        guard let currentTrack else { return .queued }
        return viewModel.trackStatuses[currentTrack.id] ?? .queued
    }

    private var currentTrackTitle: String {
        currentTrack?.name ?? "Preparing update scope"
    }

    private var currentTrackSubtitle: String {
        guard let currentTrack else {
            return totalCount == 0 ? "No tracks in the current scope." : "Waiting for the first track."
        }
        return "\(currentTrack.artist) - \(currentTrack.album)"
    }

    private var currentTrackHelp: String {
        currentTrack.map { "Track ID: \($0.id)" } ?? "No current track"
    }

    private var doneCount: Int {
        viewModel.trackStatuses.values.count(where: { status in
            if case .done = status { return true }
            return false
        })
    }

    private var failedCount: Int {
        viewModel.failedTracks.count
    }

    private var detailRows: [ProgressTrackRowModel] {
        let knownTrackIDs = Set(tracks.map(\.id))
        let trackRows = tracks.compactMap { track -> ProgressTrackRowModel? in
            guard let status = viewModel.trackStatuses[track.id] else { return nil }
            return ProgressTrackRowModel(
                id: track.id,
                title: track.name,
                subtitle: "\(track.artist) - \(track.album)",
                status: status,
                help: "Track ID: \(track.id)"
            )
        }

        let fallbackRows = viewModel.trackStatuses.keys
            .filter { !knownTrackIDs.contains($0) }
            .sorted()
            .map { trackID in
                ProgressTrackRowModel(
                    id: trackID,
                    title: "Unknown track",
                    subtitle: "Track ID: \(trackID)",
                    status: viewModel.trackStatuses[trackID] ?? .queued,
                    help: "Track ID: \(trackID)"
                )
            }

        return trackRows + fallbackRows
    }

    private var isTestArtistScopeActive: Bool {
        !normalizedTestArtists.isEmpty
    }

    private var normalizedTestArtists: [String] {
        ArtistAllowList.normalized(testArtists)
    }

    private var testArtistScopeTitle: String {
        if normalizedTestArtists.count == 1, let artist = normalizedTestArtists.first {
            return "Test Artist: \(artist)"
        }
        return "Test Artists: \(normalizedTestArtists.count)"
    }

    private var cancelHelpText: String {
        if viewModel.previewOnly {
            return "Cancel stops the preview scan and returns to configuration."
        }
        return "Cancel stops after the current operation when possible. Already written Music.app changes remain."
    }

    // MARK: - Small Components

    private func progressPill(
        _ title: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(AppFont.caption)
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xxs)
            .background(tint.opacity(0.12), in: .capsule)
    }
}

// MARK: - Progress Track Row

private struct ProgressTrackRowModel: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let status: TrackProcessingStatus
    let help: String
}

private struct ProgressTrackRow: View {
    let row: ProgressTrackRowModel

    var body: some View {
        HStack(spacing: Spacing.sm) {
            statusIndicator(for: row.status)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(AppFont.subheadline)
                    .foregroundStyle(statusForeground(for: row.status))
                    .lineLimit(1)
                Text(row.subtitle)
                    .font(AppFont.caption)
                    .foregroundStyle(Ayu.fgSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Spacing.sm)

            statusLabel(for: row.status)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(Ayu.bgTertiary.opacity(0.65), in: .rect(cornerRadius: Radius.xs))
        .help(row.help)
    }
}

// MARK: - Status Rendering

@ViewBuilder
private func statusIndicator(for status: TrackProcessingStatus) -> some View {
    switch status {
    case .queued:
        Circle()
            .fill(Ayu.fgMuted)
            .frame(width: 8, height: 8)
    case .analyzing, .writing:
        ProgressView()
            .controlSize(.small)
    case .done:
        Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(Ayu.success)
    case .failed:
        Image(systemName: "xmark.circle.fill")
            .foregroundStyle(Ayu.error)
    case .skipped:
        Image(systemName: "minus.circle")
            .foregroundStyle(Ayu.fgMuted)
    }
}

private func statusLabel(for status: TrackProcessingStatus) -> some View {
    Text(statusText(for: status))
        .font(AppFont.caption)
        .foregroundStyle(statusForeground(for: status))
}

private func statusText(for status: TrackProcessingStatus) -> String {
    switch status {
    case .queued: "Queued"
    case .analyzing: "Analyzing"
    case .writing: "Writing"
    case .done: "Updated"
    case let .failed(message): "Failed: \(message)"
    case .skipped: "Skipped"
    }
}

private func statusForeground(for status: TrackProcessingStatus) -> Color {
    switch status {
    case .queued, .skipped: Ayu.fgMuted
    case .analyzing, .writing: Ayu.accent
    case .done: Ayu.success
    case .failed: Ayu.error
    }
}
