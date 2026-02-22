// MetricCard.swift — Dashboard metric card.

import SharedUI
import SwiftUI

// MARK: - Trend Direction

/// Optional trend indicator for metric cards.
enum TrendDirection: Sendable {
    case up
    case down
    case flat

    var icon: String {
        switch self {
        case .up: "arrow.up.right"
        case .down: "arrow.down.right"
        case .flat: "arrow.right"
        }
    }

    var tint: Color {
        switch self {
        case .up: Ayu.success
        case .down: Ayu.error
        case .flat: Ayu.fgSecondary
        }
    }
}

// MARK: - MetricCard

/// Compact stat card showing an icon, primary value, title, and optional subtitle with trend.
///
/// Used on the dashboard to display key library metrics (unique genres, tracks needing year, etc.).
struct MetricCard: View {
    let title: String
    let value: String
    let subtitle: String?
    let icon: String
    let tint: Color
    var trend: TrendDirection?

    init(
        title: String,
        value: String,
        subtitle: String? = nil,
        icon: String,
        tint: Color,
        trend: TrendDirection? = nil
    ) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.icon = icon
        self.tint = tint
        self.trend = trend
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            headerRow
            valueLabel
            footerRow
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
        .background(Ayu.bgSecondary, in: RoundedRectangle(cornerRadius: Radius.md))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
        .accessibilityValue(subtitle ?? "")
    }

    // MARK: - Subviews

    private var headerRow: some View {
        HStack {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Spacer()
            if let trend {
                Image(systemName: trend.icon)
                    .font(AppFont.caption)
                    .foregroundStyle(trend.tint)
                    .accessibilityHidden(true)
            }
        }
    }

    private var valueLabel: some View {
        Text(value)
            .font(AppFont.metricSmall)
            .foregroundStyle(Ayu.fgPrimary)
            .contentTransition(.numericText())
    }

    private var footerRow: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(title)
                .font(AppFont.caption)
                .foregroundStyle(Ayu.fgSecondary)
            if let subtitle {
                Text(subtitle)
                    .font(AppFont.caption)
                    .foregroundStyle(Ayu.fgMuted)
            }
        }
    }
}

// MARK: - Preview

#Preview("Metric Cards") {
    HStack(spacing: Spacing.md) {
        MetricCard(
            title: "Unique Genres",
            value: "42",
            subtitle: "across library",
            icon: "tag.fill",
            tint: Ayu.purple
        )

        MetricCard(
            title: "Missing Year",
            value: "1,204",
            subtitle: "tracks need attention",
            icon: "calendar.badge.exclamationmark",
            tint: Ayu.warning,
            trend: .down
        )

        MetricCard(
            title: "Recently Updated",
            value: "86",
            subtitle: "last 7 days",
            icon: "clock.arrow.circlepath",
            tint: Ayu.success,
            trend: .up
        )
    }
    .padding()
    .frame(width: 600)
}
