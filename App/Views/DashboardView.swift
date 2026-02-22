// DashboardView.swift — Library Health dashboard.

import Core
import SharedUI
import SwiftUI

// MARK: - Dashboard View

/// Top-level dashboard assembling a health gauge, metric cards, and quick action buttons.
///
/// Receives a pre-loaded track array from the parent (MainView) and delegates
/// metric computation to `DashboardViewModel`. Quick actions navigate to other
/// sidebar categories via a callback.
struct DashboardView: View {
    @State private var viewModel = DashboardViewModel()
    let tracks: [Track]
    let onNavigate: (NavigationCategory) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                gaugeSection
                    .padding(.bottom, Spacing.xxxl)

                metricsSection
                    .padding(.bottom, Spacing.xxl)

                topGenresSection
                    .padding(.bottom, Spacing.xxl)

                quickActionsSection
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.xxl)
        }
        .task(id: tracks.count) {
            viewModel.refresh(tracks: tracks)
        }
    }

    // MARK: - Gauge Section

    private var gaugeSection: some View {
        GaugeView(
            totalTracks: viewModel.totalTracks,
            genreFillPercent: viewModel.genreFillPercent,
            yearFillPercent: viewModel.yearFillPercent,
            size: 280
        )
        .frame(maxWidth: .infinity)
    }

    // MARK: - Metrics Section

    private var metricsSection: some View {
        HStack(spacing: Spacing.md) {
            MetricCard(
                title: "Unique Genres",
                value: viewModel.uniqueGenres.formatted(),
                subtitle: genreSubtitle,
                icon: "tag.fill",
                tint: Ayu.purple
            )

            MetricCard(
                title: "Need Year",
                value: viewModel.tracksNeedingYear.formatted(),
                subtitle: yearSubtitle,
                icon: "calendar.badge.exclamationmark",
                tint: Ayu.warning
            )

            MetricCard(
                title: "Recently Added",
                value: viewModel.recentlyAdded.formatted(),
                subtitle: "last 7 days",
                icon: "clock.arrow.circlepath",
                tint: Ayu.success
            )
        }
    }

    // MARK: - Top Genres Section

    @ViewBuilder
    private var topGenresSection: some View {
        if !viewModel.topGenres.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Top Genres")
                    .font(AppFont.headline)
                    .foregroundStyle(Ayu.fgPrimary)

                let maxCount = viewModel.topGenres.first?.count ?? 1
                VStack(spacing: Spacing.xs) {
                    ForEach(Array(viewModel.topGenres.enumerated()), id: \.offset) { _, genre in
                        genreBarRow(name: genre.name, count: genre.count, maxCount: maxCount)
                    }
                }
                .padding(Spacing.md)
                .background(Ayu.bgSecondary, in: RoundedRectangle(cornerRadius: Radius.md))
            }
        }
    }

    private func genreBarRow(name: String, count: Int, maxCount: Int) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(name)
                .font(AppFont.body)
                .foregroundStyle(Ayu.fgPrimary)
                .frame(width: 120, alignment: .leading)
                .lineLimit(1)

            GeometryReader { geometry in
                let fraction = maxCount > 0 ? CGFloat(count) / CGFloat(maxCount) : 0
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: Radius.xs)
                        .fill(Ayu.purple.opacity(0.15))
                        .frame(width: geometry.size.width)

                    RoundedRectangle(cornerRadius: Radius.xs)
                        .fill(Ayu.purple.opacity(0.6))
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 20)

            Text(count.formatted())
                .font(AppFont.caption)
                .foregroundStyle(Ayu.fgSecondary)
                .frame(width: 40, alignment: .trailing)
                .monospacedDigit()
        }
        .frame(height: 24)
    }

    // MARK: - Quick Actions Section

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Quick Actions")
                .font(AppFont.headline)
                .foregroundStyle(Ayu.fgPrimary)

            HStack(spacing: Spacing.md) {
                QuickActionButton(
                    title: "Update Genres",
                    icon: "tag.fill",
                    tint: Ayu.purple,
                    badge: viewModel.tracksNeedingGenre
                ) {
                    onNavigate(.update)
                }

                QuickActionButton(
                    title: "Update Years",
                    icon: "calendar",
                    tint: Ayu.info,
                    badge: viewModel.tracksNeedingYear
                ) {
                    onNavigate(.update)
                }

                QuickActionButton(
                    title: "View Reports",
                    icon: "chart.bar.fill",
                    tint: Ayu.accent,
                    badge: nil
                ) {
                    onNavigate(.reports)
                }
            }
        }
    }

    // MARK: - Helpers

    private var genreSubtitle: String {
        if viewModel.tracksNeedingGenre > 0 {
            return "\(viewModel.tracksNeedingGenre.formatted()) need genre"
        }
        return "all tracks tagged"
    }

    private var yearSubtitle: String {
        if viewModel.tracksNeedingYear > 0 {
            return "\(viewModel.tracksNeedingYear.formatted()) need year"
        }
        return "all tracks dated"
    }
}

// MARK: - Preview

#Preview("Dashboard — Populated") {
    DashboardView(
        tracks: PreviewData.sampleTracks,
        onNavigate: { _ in }
    )
    .frame(width: 700, height: 800)
}

#Preview("Dashboard — Empty") {
    DashboardView(
        tracks: [],
        onNavigate: { _ in }
    )
    .frame(width: 700, height: 800)
}

// MARK: - Preview Data

private enum PreviewData {
    static let sampleTracks: [Track] = {
        var tracks: [Track] = []
        let genres = ["Rock", "Metal", "Electronic", "Jazz", "Classical", nil]
        let artists = ["Artist A", "Artist B", "Artist C", "Artist D"]
        for index in 0 ..< 150 {
            tracks.append(Track(
                id: "track-\(index)",
                name: "Track \(index)",
                artist: artists[index % artists.count],
                album: "Album \(index / 10)",
                genre: genres[index % genres.count],
                year: index.isMultiple(of: 3) ? nil : 2000 + (index % 25),
                dateAdded: index < 20 ? .now.addingTimeInterval(Double(-index * 3600)) : nil
            ))
        }
        return tracks
    }()
}
