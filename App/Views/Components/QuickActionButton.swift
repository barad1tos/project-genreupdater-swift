// QuickActionButton.swift — Horizontal action button with hover state.

import SharedUI
import SwiftUI

// MARK: - QuickActionButton

/// Horizontal quick action button with icon, title, optional badge, and hover highlight.
///
/// Designed for macOS — uses `onHover` for interactive feedback. Layout is
/// icon-left + text-right (horizontal), unlike the phone-pattern icon-above-text.
struct QuickActionButton: View {
    let title: String
    let icon: String
    let tint: Color
    let badge: Int?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundStyle(tint)
                        .frame(width: 36, height: 36)

                    if let badge, badge > 0 {
                        Text(badgeText(badge))
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Ayu.warning, in: Capsule())
                            .offset(x: 8, y: -4)
                    }
                }

                Text(title)
                    .font(AppFont.subheadline)
                    .foregroundStyle(Ayu.fgPrimary)

                Spacer(minLength: 0)
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .background(
                isHovered ? Ayu.bgTertiary : Ayu.bgSecondary,
                in: RoundedRectangle(cornerRadius: Radius.md)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
    }

    private func badgeText(_ count: Int) -> String {
        count > 999 ? "\(count / 1000)k" : count.formatted()
    }
}

// MARK: - Preview

#Preview("Quick Action Buttons") {
    VStack(spacing: Spacing.md) {
        HStack(spacing: Spacing.md) {
            QuickActionButton(
                title: "Update Genres",
                icon: "tag.fill",
                tint: Ayu.purple,
                badge: 1204,
                action: {}
            )

            QuickActionButton(
                title: "Update Years",
                icon: "calendar",
                tint: Ayu.info,
                badge: 856,
                action: {}
            )

            QuickActionButton(
                title: "View Reports",
                icon: "chart.bar.fill",
                tint: Ayu.accent,
                badge: nil,
                action: {}
            )
        }
    }
    .padding()
    .frame(width: 600)
}
