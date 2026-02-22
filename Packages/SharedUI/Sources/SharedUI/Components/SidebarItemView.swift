// SidebarItemView.swift — Individual sidebar row with matchedGeometryEffect pill and hover state.

import SwiftUI

// MARK: - SidebarItemView

/// A single sidebar navigation row with sliding pill indicator and hover highlight.
///
/// The active item renders a `matchedGeometryEffect` pill that slides between items.
/// Non-active items show a subtle `bgTertiary` hover highlight.
public struct SidebarItemView: View {
    public let title: String
    public let icon: NSImage
    public let isSelected: Bool
    public let isCompact: Bool
    public let namespace: Namespace.ID
    public let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        title: String,
        icon: NSImage,
        isSelected: Bool,
        isCompact: Bool,
        namespace: Namespace.ID,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.isSelected = isSelected
        self.isCompact = isCompact
        self.namespace = namespace
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                lucideIcon
                if !isCompact {
                    Text(title)
                        .font(AppFont.body)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
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
    }

    // MARK: - Icon

    private var lucideIcon: some View {
        let templateIcon = (icon.copy() as? NSImage) ?? icon
        templateIcon.isTemplate = true
        return Image(nsImage: templateIcon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 18, height: 18)
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
