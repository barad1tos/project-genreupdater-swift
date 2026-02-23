// AlbumCardContent.swift -- Compact album card for card lift overlay.

import Core
import SharedUI
import SwiftUI

// MARK: - Album Card Content

/// Compact album detail card shown when double-clicking an album row.
///
/// Displays album name, artist, metadata summary, and a scrollable tracklist
/// with per-track tag status indicators. This is a compact variant of
/// BrowseDetailView, view-only with no selection.
struct AlbumCardContent: View {
    let album: AlbumSummary
    let tracks: [Track]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                header
                metadataRow
                Divider()
                    .foregroundStyle(Ayu.bgTertiary)
                tracklist
            }
            .padding(Spacing.md)
        }
        .frame(maxHeight: 500)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(album.name)
                .font(AppFont.headline)
                .foregroundStyle(Ayu.fgPrimary)
                .lineLimit(2)

            Text(album.artist)
                .font(AppFont.caption)
                .foregroundStyle(Ayu.fgSecondary)
        }
    }

    // MARK: - Metadata Row

    private var metadataRow: some View {
        HStack(spacing: Spacing.sm) {
            if let year = album.year {
                Text(String(year))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Ayu.fgSecondary)
            }

            if let genre = album.primaryGenre {
                Text(genre)
                    .font(AppFont.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.xs)
                    .padding(.vertical, 2)
                    .background(Ayu.purple, in: Capsule())
            }

            Text("\(tracks.count) track\(tracks.count == 1 ? "" : "s")")
                .font(AppFont.caption)
                .foregroundStyle(Ayu.fgSecondary)

            Spacer()

            Text(healthPercentage)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Ayu.fgSecondary)
        }
    }

    private var healthPercentage: String {
        let percentage = Int(album.healthRatio * 100)
        return "\(percentage)% tagged"
    }

    // MARK: - Tracklist

    private var tracklist: some View {
        VStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                trackRow(track, number: track.originalPosition ?? (index + 1))
            }
        }
    }

    private func trackRow(_ track: Track, number: Int) -> some View {
        HStack(spacing: Spacing.xs) {
            Text("\(number)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Ayu.fgMuted)
                .frame(width: 24, alignment: .trailing)

            Text(track.name)
                .font(AppFont.body)
                .foregroundStyle(Ayu.fgPrimary)
                .lineLimit(1)

            Spacer()

            Text(track.genre ?? "\u{2014}")
                .font(AppFont.caption)
                .foregroundStyle(track.genre != nil ? Ayu.fgSecondary : Ayu.fgMuted)

            Text(track.year.map { String($0) } ?? "\u{2014}")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(track.year != nil ? Ayu.fgSecondary : Ayu.fgMuted)

            trackStatusDot(track)
        }
        .padding(.vertical, Spacing.xxs)
    }

    // MARK: - Track Status Dot

    private func trackStatusDot(_ track: Track) -> some View {
        let hasGenre = track.genre.map { !$0.isEmpty } ?? false
        let hasYear = track.year != nil

        let color: Color = if hasGenre, hasYear {
            Ayu.success
        } else if hasGenre || hasYear {
            Ayu.warning
        } else {
            Ayu.error
        }

        return Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }
}
