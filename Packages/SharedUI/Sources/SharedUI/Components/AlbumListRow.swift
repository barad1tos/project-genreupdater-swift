// AlbumListRow.swift — Album row with genre badge, year, and hover/press/selected states.

import SwiftUI

// MARK: - AlbumListRow

/// A list row displaying an album title with optional genre badge and year.
///
/// Shares the same interaction trio as ArtistListRow: leading accent bar on
/// hover/selected, 0.98x press scale, and `.contentShape(.rect)` scroll fix.
public struct AlbumListRow: View {
    private let title: String
    private let genre: String?
    private let year: Int?
    private let isSelected: Bool

    @State private var isHovered = false
    @State private var isPressed = false

    public init(
        title: String,
        genre: String? = nil,
        year: Int? = nil,
        isSelected: Bool = false
    ) {
        self.title = title
        self.genre = genre
        self.year = year
        self.isSelected = isSelected
    }

    public var body: some View {
        HStack(spacing: Spacing.xs) {
            accentBar

            Text(title)
                .font(AppFont.body)
                .foregroundStyle(Ayu.fgPrimary)
                .lineLimit(1)

            Spacer()

            if let genre {
                genreBadge(genre)
            }

            if let year {
                Text(String(year))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Ayu.fgSecondary)
            }
        }
        .padding(.horizontal, Spacing.xs)
        .frame(height: 44)
        .background {
            RoundedRectangle(cornerRadius: Radius.xs)
                .fill(rowBackgroundColor)
        }
        .contentShape(.rect)
        .scaleEffect(isPressed ? 0.98 : 1.0)
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
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Subviews

    private var accentBar: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Ayu.accent)
            .frame(width: 3)
            .opacity(isHovered || isSelected ? 1 : 0)
    }

    private func genreBadge(_ text: String) -> some View {
        Text(text)
            .font(AppFont.caption)
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

    private var accessibilityDescription: String {
        var parts = [title]
        if let genre {
            parts.append(genre)
        }
        if let year {
            parts.append(String(year))
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Preview

#Preview("AlbumListRow States") {
    VStack(spacing: Spacing.xxs) {
        AlbumListRow(title: "OK Computer", genre: "Rock", year: 1997)
        AlbumListRow(title: "Kid A", genre: "Electronic", year: 2000)
        AlbumListRow(title: "In Rainbows", year: 2007)
        AlbumListRow(title: "Amnesiac", genre: "Art Rock", year: 2001, isSelected: true)
        AlbumListRow(title: "A Moon Shaped Pool", genre: "Art Rock", year: 2016)
    }
    .padding()
    .frame(width: 400)
}
