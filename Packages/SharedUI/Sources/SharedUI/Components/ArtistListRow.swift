// ArtistListRow.swift — Artist row with count badges and hover/press/selected states.

import SwiftUI

// MARK: - ArtistListRow

/// A list row displaying an artist name with album and track count badges.
///
/// Shows a leading accent bar on hover/selected, 0.97x press scale, and
/// SF Mono count badges for column-aligned numeric display.
public struct ArtistListRow: View {
    private let name: String
    private let albumCount: Int
    private let trackCount: Int
    private let isSelected: Bool

    @State private var isHovered = false
    @State private var isPressed = false

    public init(
        name: String,
        albumCount: Int,
        trackCount: Int,
        isSelected: Bool = false
    ) {
        self.name = name
        self.albumCount = albumCount
        self.trackCount = trackCount
        self.isSelected = isSelected
    }

    public var body: some View {
        HStack(spacing: Spacing.xs) {
            accentBar

            Text(name)
                .font(AppFont.body)
                .foregroundStyle(Ayu.fgPrimary)
                .lineLimit(1)

            Spacer()

            countBadge("\(albumCount)a")
            countBadge("\(trackCount)t")
        }
        .padding(.horizontal, Spacing.xs)
        .frame(height: 44)
        .background {
            RoundedRectangle(cornerRadius: Radius.xs)
                .fill(rowBackgroundColor)
        }
        .contentShape(.rect)
        .scaleEffect(isPressed ? 0.97 : 1.0)
        .animation(Motion.curveFast, value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .onHover { hovering in
            withAnimation(Motion.curveFast) {
                isHovered = hovering
            }
        }
        .focusable()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(albumCount) albums, \(trackCount) tracks")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Subviews

    private var accentBar: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Ayu.accent)
            .frame(width: 3)
            .opacity(isHovered || isSelected ? 1 : 0)
    }

    private func countBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(Ayu.fgSecondary)
            .padding(.horizontal, Spacing.xxs + 2)
            .padding(.vertical, 2)
            .background(Ayu.bgTertiary, in: RoundedRectangle(cornerRadius: Radius.xs))
    }

    private var rowBackgroundColor: Color {
        if isSelected {
            Ayu.accent.opacity(0.1)
        } else if isHovered {
            Ayu.bgTertiary.opacity(0.5)
        } else {
            Color.clear
        }
    }
}

// MARK: - Preview

#Preview("ArtistListRow States") {
    VStack(spacing: Spacing.xxs) {
        ArtistListRow(name: "Radiohead", albumCount: 9, trackCount: 142)
        ArtistListRow(name: "Daft Punk", albumCount: 4, trackCount: 67)
        ArtistListRow(name: "Bjork", albumCount: 11, trackCount: 186, isSelected: true)
        ArtistListRow(name: "Massive Attack", albumCount: 5, trackCount: 78)
        ArtistListRow(name: "Portishead", albumCount: 3, trackCount: 34)
    }
    .padding()
    .frame(width: 360)
}
