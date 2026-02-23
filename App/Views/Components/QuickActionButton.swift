// QuickActionButton.swift — Soft quick action with neutral tone and zero-state checkmark.

import SharedUI
import SwiftUI

// MARK: - QuickActionButton

/// Horizontal quick action row with neutral tone and zero-count checkmark.
///
/// Displays context-rich information ("Genre . 327 untagged") instead of urgency-driven
/// CTAs. When count reaches zero, shows a checkmark with "All genres tagged" confirmation.
/// Designed for macOS with hover feedback and right chevron affordance.
struct QuickActionButton: View {
    let category: String
    let untaggedCount: Int
    let icon: String
    let tint: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 24)

                if untaggedCount > 0 {
                    Text("\(category) \u{00B7} \(untaggedCount.formatted()) untagged")
                        .font(AppFont.body)
                        .foregroundStyle(Ayu.fgPrimary)
                } else {
                    HStack(spacing: Spacing.xxs) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Ayu.success)
                        Text("All \(category.lowercased())s tagged")
                            .font(AppFont.body)
                            .foregroundStyle(Ayu.fgSecondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(AppFont.caption)
                    .foregroundStyle(Ayu.fgMuted)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(isHovered ? Ayu.bgTertiary.opacity(0.5) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Motion.curveFast) {
                isHovered = hovering
            }
        }
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        if untaggedCount > 0 {
            return "\(category): \(untaggedCount) untagged"
        }
        return "All \(category.lowercased())s tagged"
    }
}

// MARK: - Preview

#Preview("Quick Actions — With Counts") {
    VStack(spacing: Spacing.xs) {
        QuickActionButton(
            category: "Genre",
            untaggedCount: 327,
            icon: "tag.fill",
            tint: Ayu.purple,
            action: {}
        )
        QuickActionButton(
            category: "Year",
            untaggedCount: 1204,
            icon: "calendar",
            tint: Ayu.info,
            action: {}
        )
    }
    .padding()
    .frame(width: 400)
}

#Preview("Quick Actions — Zero State") {
    VStack(spacing: Spacing.xs) {
        QuickActionButton(
            category: "Genre",
            untaggedCount: 0,
            icon: "tag.fill",
            tint: Ayu.purple,
            action: {}
        )
        QuickActionButton(
            category: "Year",
            untaggedCount: 0,
            icon: "calendar",
            tint: Ayu.info,
            action: {}
        )
    }
    .padding()
    .frame(width: 400)
}
