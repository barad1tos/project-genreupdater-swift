// BrowseDetailView.swift — Album detail panel for NavigationSplitView third column.

import AppKit
import Core
import SharedUI
import SwiftUI

// MARK: - BrowseDetailView

/// Detail panel showing album content when browsing, or a HeroGauge watermark when empty.
///
/// Lives in the NavigationSplitView third column. Displays album art placeholder,
/// artist/album metadata, prev/next navigation, and a track list with per-track
/// tag status indicators.
struct BrowseDetailView: View {
    @Bindable var viewModel: BrowseViewModel

    var body: some View {
        if let album = viewModel.selectedAlbum {
            albumDetailContent(album)
        } else {
            emptyDetailState
        }
    }

    // MARK: - Empty State

    private var emptyDetailState: some View {
        HeroGauge(
            genreCoverage: 0,
            yearCoverage: 0,
            consistencyCoverage: 0,
            trackCount: 0
        )
        .opacity(0.15)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Album Detail

    private func albumDetailContent(_ album: AlbumIdentifier) -> some View {
        let tracks = viewModel.tracksForAlbum(album)
        let albumInfo = viewModel.albumSummary(for: album)

        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                albumHeader(albumInfo, trackCount: tracks.count)
                navigationArrows(for: album)
                Divider()
                    .foregroundStyle(Ayu.bgTertiary)
                    .padding(.horizontal, Spacing.md)
                trackList(tracks)
            }
        }
    }

    // MARK: - Album Header

    private func albumHeader(_ info: AlbumSummary?, trackCount: Int) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            RoundedRectangle(cornerRadius: Radius.md)
                .fill(
                    LinearGradient(
                        colors: [Ayu.accent, Ayu.purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 200, height: 200)
                .overlay {
                    Text(info?.name.prefix(1).uppercased() ?? "?")
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)

            Text(info?.artist ?? "Unknown Artist")
                .font(AppFont.caption)
                .foregroundStyle(Ayu.fgSecondary)

            Text(info?.name ?? "Unknown Album")
                .font(AppFont.headline)
                .foregroundStyle(Ayu.fgPrimary)

            HStack(spacing: Spacing.sm) {
                if let year = info?.year {
                    Text(String(year))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Ayu.fgSecondary)
                }
                Text("\(trackCount) track\(trackCount == 1 ? "" : "s")")
                    .font(AppFont.caption)
                    .foregroundStyle(Ayu.fgSecondary)
                if let genre = info?.primaryGenre {
                    Text(genre)
                        .font(AppFont.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, Spacing.xs)
                        .padding(.vertical, 2)
                        .background(Ayu.purple, in: Capsule())
                }
            }
        }
        .padding(Spacing.md)
    }

    // MARK: - Navigation Arrows

    private func navigationArrows(for album: AlbumIdentifier) -> some View {
        let prev = viewModel.previousAlbum(before: album)
        let next = viewModel.nextAlbum(after: album)

        return HStack {
            if let prev {
                Button {
                    viewModel.selectedAlbum = prev
                } label: {
                    HStack(spacing: Spacing.xxs) {
                        Image(systemName: "chevron.left")
                        Text(prev.albumName)
                            .lineLimit(1)
                    }
                    .font(AppFont.caption)
                    .foregroundStyle(Ayu.fgSecondary)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if let next {
                Button {
                    viewModel.selectedAlbum = next
                } label: {
                    HStack(spacing: Spacing.xxs) {
                        Text(next.albumName)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                    }
                    .font(AppFont.caption)
                    .foregroundStyle(Ayu.fgSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
    }

    // MARK: - Track List

    private func trackList(_ tracks: [Track]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                trackRow(track, number: track.originalPosition ?? (index + 1))
            }
        }
        .padding(.horizontal, Spacing.md)
    }

    // MARK: - Track Row

    private func trackRow(_ track: Track, number: Int) -> some View {
        let isSelected = viewModel.selectedItems.contains(track.id)

        return HStack(spacing: Spacing.xs) {
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
        .padding(.horizontal, Spacing.xs)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: Radius.xs)
                    .fill(Ayu.accent.opacity(0.1))
            }
        }
        .contentShape(.rect)
        .onTapGesture {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.command) {
                viewModel.handleCheckboxToggle(track.id)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(trackAccessibilityLabel(track, number: number))
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
            .accessibilityHidden(true)
    }

    // MARK: - Helpers

    private func trackAccessibilityLabel(_ track: Track, number: Int) -> String {
        var parts = ["Track \(number)", track.name]
        if let genre = track.genre, !genre.isEmpty {
            parts.append(genre)
        }
        if let year = track.year {
            parts.append(String(year))
        }
        let hasGenre = track.genre.map { !$0.isEmpty } ?? false
        let hasYear = track.year != nil
        if hasGenre, hasYear {
            parts.append("complete metadata")
        } else if hasGenre || hasYear {
            parts.append("partial metadata")
        } else {
            parts.append("missing metadata")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Preview

#Preview("BrowseDetailView — Empty") {
    BrowseDetailView(viewModel: BrowseViewModel())
        .frame(width: 400, height: 500)
}

#Preview("BrowseDetailView — Album") {
    let viewModel = BrowseViewModel()
    viewModel.tracks = (0 ..< 12).map { index in
        Track(
            id: "detail-\(index)",
            name: "Track \(index + 1)",
            artist: "Radiohead",
            album: "OK Computer",
            genre: index < 10 ? "Alternative" : nil,
            year: index < 8 ? 1997 : nil,
            originalPosition: index + 1
        )
    }
    viewModel.selectedAlbum = AlbumIdentifier(
        albumName: "OK Computer",
        artistName: "Radiohead"
    )

    return BrowseDetailView(viewModel: viewModel)
        .frame(width: 400, height: 600)
}
