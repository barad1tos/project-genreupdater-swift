// MetricCard.swift — Dashboard metric card with trend hover and click navigation.

import SharedUI
import SwiftUI

// MARK: - MetricCard

/// Compact stat card showing a metric value, trend arrow, and hover-revealed trend delta.
///
/// Follows the StatCard hover/press interaction pattern: shadow elevation + accent border
/// glow + 0.97 scale on press. Trend arrow shows direction by default; hovering reveals
/// the delta number (e.g. "+12 since last scan").
struct MetricCard: View {
    let label: String
    let value: String
    let icon: String
    let tint: Color
    var trend: TrendDirection?
    var trendDelta: Int?
    var isEnabled = true
    let onTap: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            headerRow
            valueLabel
            footerRow
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.md)
                .fill(Ayu.bgSecondary)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(Ayu.accent, lineWidth: 1.5)
                .opacity(isEnabled && isHovered ? 1 : 0)
        }
        .ayuShadow(isEnabled && isHovered ? Shadow.elevated : Shadow.subtle)
        .contentShape(.rect)
        .allowsHitTesting(isEnabled)
        .opacity(isEnabled ? 1 : 0.52)
        .scaleEffect(isEnabled && isPressed ? 0.97 : 1.0)
        .animation(Motion.curveFast, value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    isPressed = true
                }
                .onEnded { _ in
                    isPressed = false
                    onTap()
                }
        )
        .onHover { hovering in
            withAnimation(Motion.curveFast) {
                isHovered = isEnabled && hovering
            }
        }
        .onChange(of: isEnabled) { _, isEnabled in
            guard !isEnabled else { return }
            isHovered = false
            isPressed = false
        }
        .focusable(isEnabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
        .accessibilityValue(trendAccessibilityValue)
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
                HStack(spacing: Spacing.xxs) {
                    Image(systemName: trend.icon)
                        .font(AppFont.caption)
                        .foregroundStyle(trend.tint)

                    if isHovered, let delta = trendDelta {
                        Text(deltaText(delta))
                            .font(AppFont.caption)
                            .foregroundStyle(trend.tint)
                            .transition(.opacity)
                    }
                }
                .accessibilityHidden(true)
            }
        }
    }

    private var valueLabel: some View {
        Text(value)
            .font(AppFont.metricSmall)
            .foregroundStyle(Ayu.fgPrimary)
            .contentTransition(.numericText(countsDown: false))
    }

    private var footerRow: some View {
        Text(label)
            .font(AppFont.caption)
            .foregroundStyle(Ayu.fgSecondary)
    }

    // MARK: - Helpers

    private func deltaText(_ delta: Int) -> String {
        let prefix = delta > 0 ? "+" : ""
        return "\(prefix)\(delta) since last scan"
    }

    private var trendAccessibilityValue: String {
        guard let trend, let delta = trendDelta else { return "" }
        let direction = switch trend {
        case .up: "up"
        case .down: "down"
        case .flat: "flat"
        }
        return "\(direction), \(deltaText(delta))"
    }
}

// MARK: - Preview

#Preview("Metric Cards") {
    LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 180, maximum: 280))],
        spacing: Spacing.md
    ) {
        MetricCard(
            label: "Need Genre",
            value: "1,204",
            icon: "tag.fill",
            tint: Ayu.purple,
            trend: .down,
            trendDelta: -18,
            onTap: {}
        )

        MetricCard(
            label: "Need Year",
            value: "856",
            icon: "calendar.badge.exclamationmark",
            tint: Ayu.info,
            trend: .up,
            trendDelta: 5,
            onTap: {}
        )

        MetricCard(
            label: "Recently Added",
            value: "86",
            icon: "clock.arrow.circlepath",
            tint: Ayu.success,
            trend: .flat,
            trendDelta: 0,
            onTap: {}
        )
    }
    .padding()
    .frame(width: 600)
}

#Preview("Metric Card — No Trend") {
    MetricCard(
        label: "Need Genre",
        value: "0",
        icon: "tag.fill",
        tint: Ayu.purple,
        onTap: {}
    )
    .padding()
    .frame(width: 200)
}
