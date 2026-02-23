// UpdateDoneSection.swift -- Summary card with counts and final status rows.

import Core
import SharedUI
import SwiftUI

// MARK: - Update Done Section

struct UpdateDoneSection: View {
    @Bindable var viewModel: WorkflowViewModel

    private var updatedCount: Int {
        if let result = viewModel.result {
            return result.entries.count
        }
        return viewModel.completedEntries.count
    }

    private var failedResultCount: Int {
        if let result = viewModel.result {
            return result.failedTrackIDs.count
        }
        return viewModel.failedTracks.count
    }

    var body: some View {
        VStack(spacing: 0) {
            summaryCard
                .padding(Spacing.xl)
            Divider()
            finalStatusList
            Divider()
            resetBar
        }
    }

    // MARK: - Summary Card

    private var summaryCard: some View {
        HStack(spacing: Spacing.lg) {
            Image(systemName: summaryIcon)
                .font(.system(size: 36))
                .foregroundStyle(summaryColor)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Update Complete")
                    .font(AppFont.headline)
                    .foregroundStyle(Ayu.fgPrimary)

                HStack(spacing: Spacing.md) {
                    summaryMetric(
                        value: "\(updatedCount)",
                        label: "updated",
                        color: Ayu.success
                    )
                    if failedResultCount > 0 {
                        summaryMetric(
                            value: "\(failedResultCount)",
                            label: "failed",
                            color: Ayu.error
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.lg)
        .background(Ayu.bgSecondary, in: .rect(cornerRadius: Radius.md))
    }

    private var summaryIcon: String {
        failedResultCount > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
    }

    private var summaryColor: Color {
        failedResultCount > 0 ? Ayu.warning : Ayu.success
    }

    private func summaryMetric(
        value: String,
        label: String,
        color: Color
    ) -> some View {
        HStack(spacing: Spacing.xxs) {
            Text(value)
                .font(AppFont.subheadline)
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label)
                .font(AppFont.caption)
                .foregroundStyle(Ayu.fgSecondary)
        }
    }

    // MARK: - Final Status List

    private var finalStatusList: some View {
        List {
            ForEach(sortedTrackIDs, id: \.self) { trackID in
                finalStatusRow(trackID: trackID)
                    .contentShape(.rect)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    private var sortedTrackIDs: [String] {
        Array(viewModel.trackStatuses.keys).sorted()
    }

    private func finalStatusRow(trackID: String) -> some View {
        let status = viewModel.trackStatuses[trackID] ?? .done
        return HStack(spacing: Spacing.sm) {
            statusIcon(for: status)
                .frame(width: 16)

            Text(trackID)
                .font(.body)
                .lineLimit(1)
                .foregroundStyle(statusForeground(for: status))

            Spacer()

            Text(statusText(for: status))
                .font(AppFont.caption)
                .foregroundStyle(statusForeground(for: status))
        }
        .padding(.vertical, 2)
    }

    // MARK: - Status Helpers

    @ViewBuilder
    private func statusIcon(for status: TrackProcessingStatus) -> some View {
        switch status {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Ayu.success)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Ayu.error)
        case .skipped:
            Image(systemName: "minus.circle")
                .foregroundStyle(Ayu.fgMuted)
        default:
            Circle()
                .fill(Ayu.fgMuted)
                .frame(width: 8, height: 8)
        }
    }

    private func statusText(for status: TrackProcessingStatus) -> String {
        switch status {
        case .done: "Updated"
        case let .failed(message): message
        case .skipped: "Skipped"
        default: ""
        }
    }

    private func statusForeground(for status: TrackProcessingStatus) -> Color {
        switch status {
        case .done: Ayu.success
        case .failed: Ayu.error
        case .skipped: Ayu.fgMuted
        default: Ayu.fgSecondary
        }
    }

    // MARK: - Reset Bar

    private var resetBar: some View {
        HStack {
            Spacer()
            Button("Start New Update") {
                viewModel.reset()
            }
            .buttonStyle(.borderedProminent)
            .tint(Ayu.accent)
        }
        .padding(Spacing.md)
    }
}
