// FilterChip.swift — Toggle chip with active/inactive/dismiss states.

import SwiftUI

// MARK: - FilterChip

/// A compact toggle chip for filtering and categorization.
///
/// Toggles between active (accent background) and inactive (border only) states
/// with a cross-fade animation. Optionally shows a dismiss button when active.
public struct FilterChip: View {
    private let label: String
    private let isActive: Bool
    private let isDismissable: Bool
    private let onTap: () -> Void
    private let onDismiss: (() -> Void)?

    @State private var isHovered = false
    @State private var isPressed = false

    public init(
        label: String,
        isActive: Bool,
        isDismissable: Bool = false,
        onTap: @escaping () -> Void,
        onDismiss: (() -> Void)? = nil
    ) {
        self.label = label
        self.isActive = isActive
        self.isDismissable = isDismissable
        self.onTap = onTap
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: Spacing.xxs) {
            Text(label)
                .font(AppFont.caption)

            if isDismissable, isActive {
                Image(systemName: "xmark.circle")
                    .font(.caption2)
                    .onTapGesture { onDismiss?() }
            }
        }
        .foregroundStyle(isActive ? .white : Ayu.fgPrimary)
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xxs)
        .background {
            if isActive {
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(Ayu.accent)
            } else {
                RoundedRectangle(cornerRadius: Radius.sm)
                    .strokeBorder(Ayu.fgMuted.opacity(0.3), lineWidth: 1)
            }
        }
        .contentShape(.rect)
        .scaleEffect(isPressed ? 0.97 : 1.0)
        .animation(Motion.curveFast, value: isPressed)
        .animation(Motion.curveFast, value: isActive)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in
                    isPressed = false
                    onTap()
                }
        )
        .onHover { isHovered = $0 }
        .focusable()
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

// MARK: - Preview

#Preview("FilterChip States") {
    VStack(spacing: Spacing.md) {
        FilterChip(label: "Rock", isActive: true, onTap: {})
        FilterChip(label: "Jazz", isActive: false, onTap: {})
        FilterChip(
            label: "Electronic",
            isActive: true,
            isDismissable: true,
            onTap: {},
            onDismiss: {}
        )
        HStack(spacing: Spacing.xs) {
            FilterChip(label: "Pop", isActive: false, onTap: {})
            FilterChip(label: "Metal", isActive: true, onTap: {})
            FilterChip(
                label: "Classical",
                isActive: true,
                isDismissable: true,
                onTap: {},
                onDismiss: {}
            )
            FilterChip(label: "Hip-Hop", isActive: false, onTap: {})
        }
    }
    .padding()
}
