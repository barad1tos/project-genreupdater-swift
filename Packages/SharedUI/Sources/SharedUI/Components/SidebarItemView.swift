// SidebarItemView.swift — Individual sidebar row with matchedGeometryEffect pill and hover state.

import SwiftUI

// MARK: - SidebarItemView

/// A single sidebar navigation row with sliding pill indicator, hover highlight, and optional status badge.
///
/// The active item renders a `matchedGeometryEffect` pill that slides between items.
/// Non-active items show a subtle `bgTertiary` hover highlight.
public struct SidebarItemView: View {
    public let title: String
    public let icon: NSImage
    public let badge: SidebarBadge?
    public let isSelected: Bool
    public let isCompact: Bool
    public let namespace: Namespace.ID
    public let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        title: String,
        icon: NSImage,
        badge: SidebarBadge? = nil,
        isSelected: Bool,
        isCompact: Bool,
        namespace: Namespace.ID,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.badge = badge
        self.isSelected = isSelected
        self.isCompact = isCompact
        self.namespace = namespace
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                badgedIcon
                if !isCompact {
                    Text(title)
                        .font(AppFont.body)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                    Spacer(minLength: Spacing.xs)
                    if let badge {
                        expandedBadge(badge)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: isCompact ? .center : .leading)
            .foregroundStyle(isSelected ? Ayu.accent : Ayu.fgPrimary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background { pillBackground }
        .contentShape(.rect)
        .onHover { hovering in
            withAnimation(Motion.curveFast) {
                isHovered = hovering
            }
        }
        .help(isCompact ? title : "")
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Icon

    private var badgedIcon: some View {
        lucideIcon
            .overlay(alignment: .topTrailing) {
                if isCompact, let badge {
                    compactBadge(badge)
                        .offset(x: 7, y: -7)
                }
            }
    }

    private var lucideIcon: some View {
        let templateIcon = (icon.copy() as? NSImage) ?? icon
        templateIcon.isTemplate = true
        return Image(nsImage: templateIcon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 18, height: 18)
    }

    // MARK: - Badge

    private func expandedBadge(_ badge: SidebarBadge) -> some View {
        Text(badge.value)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(badgeToneColor(badge.tone))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 6)
            .frame(minWidth: 20)
            .frame(height: 18)
            .background(
                Capsule()
                    .fill(badgeToneColor(badge.tone).opacity(isSelected ? 0.22 : 0.14))
            )
            .overlay(
                Capsule()
                    .strokeBorder(badgeToneColor(badge.tone).opacity(0.28), lineWidth: 0.5)
            )
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func compactBadge(_ badge: SidebarBadge) -> some View {
        if badge.value.count <= 2, badge.value != "..." {
            Text(badge.value)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(badgeToneColor(badge.tone))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(minWidth: 14)
                .frame(height: 14)
                .background(
                    Circle()
                        .fill(badgeToneColor(badge.tone).opacity(0.18))
                )
                .overlay(
                    Circle()
                        .strokeBorder(badgeToneColor(badge.tone).opacity(0.34), lineWidth: 0.5)
                )
                .accessibilityHidden(true)
        } else {
            Circle()
                .fill(badgeToneColor(badge.tone))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
        }
    }

    private func badgeToneColor(_ tone: SidebarBadge.Tone) -> Color {
        switch tone {
        case .neutral:
            Ayu.fgSecondary
        case .info:
            Ayu.info
        case .success:
            Ayu.success
        case .warning:
            Ayu.warning
        case .critical:
            Ayu.error
        }
    }

    private var accessibilityText: String {
        guard let badge else {
            return title
        }
        return "\(title), \(badge.accessibilityLabel)"
    }

    // MARK: - Pill Background

    @ViewBuilder
    private var pillBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(Ayu.accent.opacity(0.15))
                .strokeBorder(Ayu.accent, lineWidth: 1)
                .matchedGeometryEffect(
                    id: "activeIndicator",
                    in: namespace
                )
        } else if isHovered {
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(Ayu.bgTertiary)
        }
    }
}
