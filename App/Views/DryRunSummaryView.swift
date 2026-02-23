// DryRunSummaryView.swift — Read-only summary of dry-run analysis results.
//
// Shows what changes would be applied without modifying the library:
// - Header with total/affected/confidence stats and type breakdown
// - Scrollable list of proposed changes (reuses change display components)
// - Close button (no apply action)

import Core
import Services
import SharedUI
import SwiftUI

// MARK: - Dry Run Summary View

struct DryRunSummaryView: View {
    let report: DryRunReport?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            summaryHeader
            Divider()
            if let report, !report.proposedChanges.isEmpty {
                changeList(for: report)
            } else {
                emptyState
            }
            Divider()
            actionBar
        }
    }

    // MARK: - Header

    private var summaryHeader: some View {
        VStack(spacing: Spacing.sm) {
            if let report {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "eye.fill")
                        .foregroundStyle(.blue)
                        .accessibilityHidden(true)
                    Text("Dry Run Report")
                        .font(.headline)
                    Spacer()
                }

                HStack(spacing: Spacing.md) {
                    statBadge(
                        count: report.totalChanges,
                        label: "Changes"
                    )
                    statBadge(
                        count: report.affectedTrackCount,
                        label: "Tracks"
                    )
                    statBadge(
                        count: report.averageConfidence,
                        label: "Avg Confidence"
                    )
                    Spacer()
                }

                if !report.changesByType.isEmpty {
                    typeBreakdown(report: report)
                }
            }
        }
        .padding()
    }

    private func statBadge(
        count: Int,
        label: String
    ) -> some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.title3)
                .bold()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func typeBreakdown(
        report: DryRunReport
    ) -> some View {
        HStack(spacing: Spacing.sm) {
            ForEach(
                report.changesByType,
                id: \.type
            ) { entry in
                Label(
                    "\(entry.count) \(entry.type.displayLabel)",
                    systemImage: entry.type.iconName
                )
                .font(.caption)
                .foregroundStyle(entry.type.tintColor)
            }
            Spacer()
        }
    }

    // MARK: - Change List

    private func changeList(
        for report: DryRunReport
    ) -> some View {
        List(report.proposedChanges) { change in
            changeRow(change)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    private func changeRow(
        _ change: ProposedChange
    ) -> some View {
        HStack(spacing: Spacing.sm) {
            changeTypeIcon(for: change.changeType)

            VStack(alignment: .leading, spacing: 2) {
                Text(change.track.name)
                    .font(.body)
                    .lineLimit(1)
                Text(change.track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            changeValueLabel(
                oldValue: change.oldValue,
                newValue: change.newValue
            )

            ConfidenceBadge(
                confidence: Double(change.confidence) / 100.0
            )
        }
        .padding(.vertical, 2)
    }

    // MARK: - Shared Display Helpers

    private func changeTypeIcon(
        for changeType: ChangeType
    ) -> some View {
        Image(
            systemName: changeType.iconName
        )
        .foregroundStyle(changeType.tintColor)
        .frame(width: 20)
        .accessibilityHidden(true)
    }

    private func changeValueLabel(
        oldValue: String?,
        newValue: String?
    ) -> some View {
        HStack(spacing: Spacing.xxs) {
            Text(oldValue ?? "none")
                .foregroundStyle(.secondary)
                .strikethrough()
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(newValue ?? "none")
                .foregroundStyle(.primary)
                .bold()
        }
        .font(.callout)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "from \(oldValue ?? "none") to \(newValue ?? "none")"
        )
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: Spacing.sm) {
            Spacer()
            Image(systemName: "checkmark.seal")
                .font(.largeTitle)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("No changes needed")
                .font(.headline)
            Text(
                "All tracks already have optimal metadata "
                    + "at the current confidence threshold."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack {
            Spacer()
            Button("Close") {
                onClose()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
        .background(.bar)
    }
}
