// ArtistCardContent.swift -- Rich artist detail card for card lift overlay.

import Core
import SharedUI
import SwiftUI

// MARK: - Artist Card Content

/// Rich artist detail card shown when double-clicking an artist row.
///
/// Displays artist name, album/track count, a mini HeroGauge watermark,
/// top genre statistics, and a scrollable album list with cascade navigation.
struct ArtistCardContent: View {
    let artist: ArtistGroup
    let albums: [AlbumSummary]
    let tracks: [Track]
    let onAlbumDoubleTap: (AlbumSummary) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                header
                genreStatistics
                albumList
            }
            .padding(Spacing.md)
        }
        .frame(maxHeight: 500)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(artist.canonicalName)
                    .font(AppFont.headline)
                    .foregroundStyle(Ayu.fgPrimary)
                    .lineLimit(2)

                Text(
                    "\(artist.albumCount) album\(artist.albumCount == 1 ? "" : "s"), \(artist.totalTrackCount) track\(artist.totalTrackCount == 1 ? "" : "s")"
                )
                .font(AppFont.caption)
                .foregroundStyle(Ayu.fgSecondary)
            }

            Spacer()

            miniGaugeWatermark
        }
    }

    // MARK: - Mini HeroGauge Watermark

    private var miniGaugeWatermark: some View {
        let genreCoverage = tracks.isEmpty ? 0 : Double(tracks.count(where: {
            $0.genre.map { !$0.isEmpty } ?? false
        })) / Double(tracks.count)

        let yearCoverage = tracks.isEmpty ? 0 : Double(tracks.count(where: {
            $0.year != nil
        })) / Double(tracks.count)

        let consistencyCoverage = tracks.isEmpty ? 0 : Double(tracks.count(where: {
            ($0.genre.map { !$0.isEmpty } ?? false) && $0.year != nil
        })) / Double(tracks.count)

        return HeroGauge(
            genreCoverage: genreCoverage,
            yearCoverage: yearCoverage,
            consistencyCoverage: consistencyCoverage,
            trackCount: tracks.count
        )
        .frame(width: 120, height: 70)
        .opacity(0.3)
    }

    // MARK: - Genre Statistics

    private var genreStatistics: some View {
        let genreCounts = Dictionary(grouping: tracks.filter {
            $0.genre.map { !$0.isEmpty } ?? false
        }) { $0.genre ?? "" }
            .mapValues(\.count)
            .sorted { $0.value > $1.value }
            .prefix(3)

        let maxCount = genreCounts.first?.value ?? 1

        return VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Top Genres")
                .font(AppFont.caption)
                .foregroundStyle(Ayu.fgMuted)

            if genreCounts.isEmpty {
                Text("No genres tagged")
                    .font(AppFont.caption)
                    .foregroundStyle(Ayu.fgMuted)
                    .italic()
            } else {
                ForEach(Array(genreCounts), id: \.key) { genre, count in
                    HStack(spacing: Spacing.xs) {
                        Text(genre)
                            .font(AppFont.body)
                            .foregroundStyle(Ayu.fgPrimary)
                            .frame(width: 120, alignment: .leading)
                            .lineLimit(1)

                        GeometryReader { geometry in
                            RoundedRectangle(cornerRadius: Radius.xs)
                                .fill(Ayu.accent)
                                .frame(
                                    width: geometry.size.width * CGFloat(count) / CGFloat(maxCount)
                                )
                        }
                        .frame(height: 8)

                        Text("\(count)")
                            .font(AppFont.mono)
                            .foregroundStyle(Ayu.fgSecondary)
                            .frame(width: 32, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Album List

    private var albumList: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Albums")
                .font(AppFont.caption)
                .foregroundStyle(Ayu.fgMuted)

            ForEach(albums) { album in
                albumRow(album)
            }
        }
    }

    private func albumRow(_ album: AlbumSummary) -> some View {
        HStack(spacing: Spacing.xs) {
            Text(album.name)
                .font(AppFont.body)
                .foregroundStyle(Ayu.fgPrimary)
                .lineLimit(1)

            Spacer()

            if let year = album.year {
                Text(String(year))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Ayu.fgSecondary)
            }

            Text("\(album.trackCount)")
                .font(AppFont.mono)
                .foregroundStyle(Ayu.fgMuted)
                .frame(width: 24, alignment: .trailing)

            healthDot(album.healthRatio)
        }
        .padding(.vertical, Spacing.xxs)
        .padding(.horizontal, Spacing.xs)
        .background(Ayu.bgSecondary, in: RoundedRectangle(cornerRadius: Radius.xs))
        .contentShape(.rect)
        .overlay {
            DoubleClickDetector {
                onAlbumDoubleTap(album)
            }
        }
    }

    // MARK: - Health Dot

    private func healthDot(_ ratio: Double) -> some View {
        let color: Color = if ratio >= 0.9 {
            Ayu.success
        } else if ratio >= 0.5 {
            Ayu.warning
        } else {
            Ayu.error
        }

        return Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }
}
