// ArtistRow.swift — Artist list row with health indicator and genre pill.

import SharedUI
import SwiftUI

// MARK: - Artist Row

/// Compact row displaying an artist's name, track count, primary genre,
/// and a health dot indicating metadata completeness.
///
/// Health dot colors:
/// - Green (success): all tracks have both genre and year
/// - Orange (warning): some tracks missing metadata
/// - Red (error): many tracks missing metadata (below 50%)
struct ArtistRow: View {
    let name: String
    let trackCount: Int
    let primaryGenre: String?
    let healthRatio: Double

    var body: some View {
        HStack(spacing: Spacing.sm) {
            healthDot
            artistInfo
            Spacer()
            genrePill
            trackCountBadge
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Subviews

    private var healthDot: some View {
        Circle()
            .fill(healthColor)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }

    private var artistInfo: some View {
        Text(name)
            .font(AppFont.body)
            .foregroundStyle(Ayu.fgPrimary)
            .lineLimit(1)
    }

    @ViewBuilder
    private var genrePill: some View {
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

    private var healthColor: Color {
        switch healthRatio {
        case 0.8 ... 1.0: Ayu.success
        case 0.5 ..< 0.8: Ayu.warning
        default: Ayu.error
        }
    }

    private var trackCountLabel: String {
        "\(trackCount) track\(trackCount == 1 ? "" : "s")"
    }

    private var accessibilityDescription: String {
        var parts = ["\(name), \(trackCountLabel)"]
        if let primaryGenre {
            parts.append("genre: \(primaryGenre)")
        }
        let healthLabel = switch healthRatio {
        case 0.8 ... 1.0: "complete metadata"
        case 0.5 ..< 0.8: "partial metadata"
        default: "incomplete metadata"
        }
        parts.append(healthLabel)
        return parts.joined(separator: ", ")
    }
}

// MARK: - Preview

#Preview("Artist Rows") {
    List {
        ArtistRow(
            name: "Metallica",
            trackCount: 247,
            primaryGenre: "Metal",
            healthRatio: 0.95
        )
        ArtistRow(
            name: "Radiohead",
            trackCount: 89,
            primaryGenre: "Alternative",
            healthRatio: 0.72
        )
        ArtistRow(
            name: "Unknown Artist",
            trackCount: 12,
            primaryGenre: nil,
            healthRatio: 0.3
        )
        ArtistRow(
            name: "Miles Davis",
            trackCount: 1,
            primaryGenre: "Jazz",
            healthRatio: 1.0
        )
    }
    .listStyle(.inset)
    .frame(width: 500, height: 300)
}
