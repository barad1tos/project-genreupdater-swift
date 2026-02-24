// StatCard.swift — Floating metric card with shadow hover elevation.

import SwiftUI

// MARK: - StatCard

/// A metric card displaying a label, value, and mini progress bar.
///
/// Elevates shadow from subtle to elevated on hover with an accent border
/// appearing simultaneously. Progress bar animates width smoothly on data changes.
public struct StatCard: View {
    private let label: String
    private let value: String
    private let progress: Double
    private let onTap: (() -> Void)?

    @State private var isHovered = false
    @State private var isPressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        label: String,
        value: String,
        progress: Double,
        onTap: (() -> Void)? = nil
    ) {
        self.label = label
        self.value = value
        self.progress = progress
        self.onTap = onTap
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(label)
                .font(AppFont.caption)
                .foregroundStyle(Ayu.fgSecondary)

            Text(value)
                .font(AppFont.metric)
                .foregroundStyle(Ayu.fgPrimary)
                .contentTransition(.numericText(countsDown: false))

            progressBar
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.md)
                .fill(Ayu.bgSecondary)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(Ayu.accent, lineWidth: 1.5)
                .opacity(isHovered ? 1 : 0)
        }
        .ayuShadow(isHovered ? Shadow.elevated : Shadow.subtle)
        .contentShape(.rect)
        .scaleEffect(isPressed ? 0.97 : 1.0)
        .animation(Motion.curveFast, value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in
                    isPressed = false
                    onTap?()
                }
        )
        .onHover { hovering in
            withAnimation(Motion.curveFast) {
                isHovered = hovering
            }
        }
        .focusable()
        .accessibilityElement(children: .combine)
    }

    private var progressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Ayu.bgTertiary)

                RoundedRectangle(cornerRadius: 2)
                    .fill(Ayu.accent)
                    .frame(
                        width: geometry.size.width * clampedProgress
                    )
                    .animation(
                        reduceMotion ? .default : Motion.curveDefault,
                        value: progress
                    )
            }
        }
        .frame(height: 4)
    }

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }
}

// MARK: - Preview

#Preview("StatCard Grid") {
    LazyVGrid(
        columns: [
            GridItem(.flexible()),
            GridItem(.flexible()),
        ],
        spacing: Spacing.md
    ) {
        StatCard(label: "Total Tracks", value: "38,085", progress: 1.0)
        StatCard(label: "Updated", value: "12,450", progress: 0.33)
        StatCard(label: "Pending", value: "25,635", progress: 0.67)
        StatCard(label: "Errors", value: "42", progress: 0.01)
    }
    .padding()
}

#Preview("StatCard Grid (Dark)") {
    LazyVGrid(
        columns: [
            GridItem(.flexible()),
            GridItem(.flexible()),
        ],
        spacing: Spacing.md
    ) {
        StatCard(label: "Total Tracks", value: "38,085", progress: 1.0)
        StatCard(label: "Updated", value: "12,450", progress: 0.33)
        StatCard(label: "Pending", value: "25,635", progress: 0.67)
        StatCard(label: "Errors", value: "42", progress: 0.01)
    }
    .padding()
    .preferredColorScheme(.dark)
}
