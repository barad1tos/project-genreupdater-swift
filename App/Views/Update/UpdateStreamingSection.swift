// UpdateStreamingSection.swift -- Streaming per-track progress with auto-scroll and compact bar.

import Core
import SharedUI
import SwiftUI

// MARK: - Update Streaming Section

struct UpdateStreamingSection: View {
    @Bindable var viewModel: WorkflowViewModel
    @State private var isUserScrolling = false

    private var groupedStatuses: [(key: String, trackIDs: [String])] {
        // Build ordered groups from the trackStatuses dictionary, grouped by artist.
        // We don't have Track objects here, so derive artist from the ID order in trackStatuses.
        // Since trackStatuses keys are track IDs, we group in insertion order via the sorted keys.
        // For proper artist grouping we would need the original tracks; use a flat list instead
        // and rely on the track IDs being in processing order.
        []
    }

    var body: some View {
        VStack(spacing: 0) {
            compactProgressBar
            Divider()
            streamingList
            Divider()
            cancelBar
        }
    }

    // MARK: - Compact Progress Bar

    private var compactProgressBar: some View {
        VStack(spacing: Spacing.xxs) {
            HStack {
                Text("\(viewModel.processedCount) / \(viewModel.totalCount)")
                    .font(AppFont.caption)
                    .monospacedDigit()
                    .foregroundStyle(Ayu.fgPrimary)
                    .contentTransition(.numericText())
                Text("\u{2014}")
                    .foregroundStyle(Ayu.fgMuted)
                Text(progressMessage)
                    .font(AppFont.caption)
                    .foregroundStyle(Ayu.fgSecondary)
                    .lineLimit(1)
                Spacer()
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Ayu.bgTertiary)
                        .frame(height: 4)
                    Capsule()
                        .fill(Ayu.accent)
                        .frame(width: geometry.size.width * progressFraction, height: 4)
                        .animation(Motion.curveFast, value: progressFraction)
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
    }

    private var progressFraction: CGFloat {
        viewModel.totalCount > 0
            ? CGFloat(viewModel.processedCount) / CGFloat(viewModel.totalCount)
            : 0
    }

    private var progressMessage: String {
        viewModel.progress?.message ?? "Processing..."
    }

    // MARK: - Streaming List

    private var streamingList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(sortedTrackIDs, id: \.self) { trackID in
                    streamingRow(trackID: trackID)
                        .id(trackID)
                        .contentShape(.rect)
                }

                if !viewModel.failedTracks.isEmpty, !hasActiveProcessing {
                    failedSection
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .onChange(of: viewModel.currentTrackID) { _, newID in
                guard !isUserScrolling, let identifier = newID else { return }
                withAnimation(Motion.curveFast) {
                    proxy.scrollTo(identifier, anchor: .center)
                }
            }
            .onScrollPhaseChange { _, newPhase in
                isUserScrolling = newPhase != .idle
            }
        }
    }

    private var sortedTrackIDs: [String] {
        // Maintain insertion order by sorting keys deterministically.
        // trackStatuses is populated in processing order, so Array(keys) preserves it.
        Array(viewModel.trackStatuses.keys).sorted()
    }

    private var hasActiveProcessing: Bool {
        viewModel.trackStatuses.values.contains { status in
            switch status {
            case .queued, .analyzing, .writing: true
            default: false
            }
        }
    }

    // MARK: - Streaming Row

    private func streamingRow(trackID: String) -> some View {
        let status = viewModel.trackStatuses[trackID] ?? .queued
        return HStack(spacing: Spacing.sm) {
            statusIndicator(for: status)
                .frame(width: 16)

            Text(trackID)
                .font(.body)
                .lineLimit(1)
                .foregroundStyle(statusForeground(for: status))

            Spacer()

            statusLabel(for: status)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Status Indicator

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

    // MARK: - Status Label

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
        case .done: "Done"
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

    // MARK: - Failed Section

    private var failedSection: some View {
        Section {
            ForEach(viewModel.failedTracks, id: \.id) { failed in
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Ayu.error)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failed.id)
                            .font(.body)
                            .lineLimit(1)
                        Text(failed.error)
                            .font(AppFont.caption)
                            .foregroundStyle(Ayu.error)
                            .lineLimit(2)
                    }
                }
                .contentShape(.rect)
            }
        } header: {
            Text("Failed (\(viewModel.failedTracks.count))")
                .font(AppFont.caption)
                .foregroundStyle(Ayu.error)
        }
    }

    // MARK: - Cancel Bar

    private var cancelBar: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) {
                viewModel.cancel()
            }
            .buttonStyle(.bordered)
        }
        .padding(Spacing.md)
    }
}
