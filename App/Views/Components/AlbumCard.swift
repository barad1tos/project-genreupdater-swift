// AlbumCard.swift — Album list row with art placeholder and metadata.

import SharedUI
import SwiftUI

// MARK: - Album Card

/// Row component for album lists showing a gradient art placeholder,
/// album name, year, track count, and primary genre badge.
///
/// The art placeholder uses the first letter of the album name rendered
/// inside a gradient circle (Ayu.accent to Ayu.purple).
struct AlbumCard: View {
    let name: String
    let artist: String
    let year: Int?
    let trackCount: Int
    let primaryGenre: String?

    var body: some View {
        HStack(spacing: Spacing.sm) {
            artPlaceholder
            albumInfo
            Spacer()
            trailingContent
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Subviews

    private var artPlaceholder: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Ayu.accent, Ayu.purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text(firstLetter)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: 36, height: 36)
        .accessibilityHidden(true)
    }

    private var albumInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(displayName)
                .font(AppFont.body)
                .foregroundStyle(Ayu.fgPrimary)
                .lineLimit(1)

            HStack(spacing: Spacing.xxs) {
                Text(artist)
                    .font(AppFont.caption)
                    .foregroundStyle(Ayu.fgSecondary)
                    .lineLimit(1)

                if let year {
                    Text("·")
                        .font(AppFont.caption)
                        .foregroundStyle(Ayu.fgMuted)

                    Text(String(year))
                        .font(AppFont.caption)
                        .foregroundStyle(Ayu.fgSecondary)
                }
            }
        }
    }

    private var trailingContent: some View {
        HStack(spacing: Spacing.xs) {
            genreBadge
            trackCountBadge
        }
    }

    @ViewBuilder
    private var genreBadge: some View {
        if let primaryGenre {
            Text(primaryGenre)
                .font(AppFont.caption)
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, Spacing.xxs)
                .background(Ayu.purple, in: Capsule())
        }
    }

    private var trackCountBadge: some View {
        Text(trackCountLabel)
            .font(AppFont.caption)
            .foregroundStyle(Ayu.fgSecondary)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxs)
            .background(Ayu.bgTertiary, in: Capsule())
    }

    // MARK: - Computed

    private var displayName: String {
        name.isEmpty ? "Unknown Album" : name
    }

    private var firstLetter: String {
        let letter = displayName.first.map(String.init) ?? "?"
        return letter.uppercased()
    }

    private var trackCountLabel: String {
        "\(trackCount) track\(trackCount == 1 ? "" : "s")"
    }

    private var accessibilityDescription: String {
        var parts = [displayName, "by \(artist)"]
        if let year {
            parts.append("released \(year)")
        }
        parts.append(trackCountLabel)
        if let primaryGenre {
            parts.append(primaryGenre)
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Preview

#Preview("Album Cards") {
    List {
        AlbumCard(
            name: "Master of Puppets",
            artist: "Metallica",
            year: 1986,
            trackCount: 8,
            primaryGenre: "Metal"
        )
        AlbumCard(
            name: "OK Computer",
            artist: "Radiohead",
            year: 1997,
            trackCount: 12,
            primaryGenre: "Alternative"
        )
        AlbumCard(
            name: "",
            artist: "Unknown Artist",
            year: nil,
            trackCount: 3,
            primaryGenre: nil
        )
        AlbumCard(
            name: "Kind of Blue",
            artist: "Miles Davis",
            year: 1959,
            trackCount: 5,
            primaryGenre: "Jazz"
        )
    }
    .listStyle(.inset)
    .frame(width: 550, height: 300)
}
