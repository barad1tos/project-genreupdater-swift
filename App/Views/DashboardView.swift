// DashboardView.swift — Library health dashboard with cached-first metrics.

import Core
import Services
import SharedUI
import SwiftUI

// MARK: - Dashboard View

/// Calm observatory showing library health state via HeroGauge, metric cards, and soft quick actions.
///
/// Uses a two-phase cached-first loading pattern: loads persisted metrics snapshot instantly
/// on appear, then refreshes from live MusicKit data when tracks arrive. First launch shows
/// full shimmer placeholders; subsequent launches never show "0 tracks".
struct DashboardView: View {
    @State private var viewModel = DashboardViewModel()
    @State private var showGauge = false
    @State private var showMetrics = false
    @State private var showActions = false
    @State private var animateGaugeEntrance = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionScale) private var motionScale

    let tracks: [Track]
    let metricsSnapshot: PersistedMetricsSnapshot?
    let isLoadingTracks: Bool
    let onNavigate: (NavigationCategory) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Shimmer/live crossfade via ZStack with opacity
                ZStack {
                    if viewModel.showShimmer {
                        shimmerContent
                            .transition(.opacity)
                    }
                    if viewModel.showLiveContent {
                        liveContent
                            .transition(.opacity)
                    }
                }
                .animation(Motion.curveCrossfade, value: viewModel.showShimmer)
                .animation(Motion.curveCrossfade, value: viewModel.showLiveContent)

                // Error states appear instantly -- no crossfade
                if case .permissionDenied = viewModel.loadingState {
                    permissionDeniedView
                }
                if case .emptyLibrary = viewModel.loadingState {
                    emptyLibraryView
                }
                if case let .error(message) = viewModel.loadingState {
                    errorView(message)
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.xxl)
        }
        .onAppear {
            viewModel.loadCachedMetrics(from: metricsSnapshot)
        }
        .task(id: tracks.count) {
            viewModel.refreshFromLive(tracks: tracks, isLoadingTracks: isLoadingTracks)
        }
        .onChange(of: viewModel.showLiveContent) { _, isVisible in
            guard isVisible else { return }
            // Capture first-load flag before clearing it
            let isFirstLoad = viewModel.isFirstLoad
            viewModel.markFirstLoadComplete()

            if reduceMotion || !isFirstLoad {
                showGauge = true
                showMetrics = true
                showActions = true
            } else {
                // First data load: stagger the entrance cascade
                animateGaugeEntrance = true
                let stagger = Motion.scaled(Motion.curveAppear, by: motionScale)
                withAnimation(stagger) { showGauge = true }
                withAnimation(stagger.delay(0.05)) { showMetrics = true }
                withAnimation(stagger.delay(0.10)) { showActions = true }
            }
        }
    }

    // MARK: - Live Content

    private var liveContent: some View {
        VStack(spacing: 0) {
            Group {
                updatingIndicator
                gaugeSection
            }
            .opacity(showGauge ? 1 : 0)

            metricsSection
                .opacity(showMetrics ? 1 : 0)

            Group {
                quickActionsSection
                timestampFooter
            }
            .opacity(showActions ? 1 : 0)
        }
    }

    // MARK: - Updating Indicator

    @ViewBuilder
    private var updatingIndicator: some View {
        if isLoadingTracks, case .cached = viewModel.loadingState {
            HStack(spacing: Spacing.xs) {
                ProgressView()
                    .controlSize(.small)
                Text("Updating...")
                    .font(AppFont.caption)
                    .foregroundStyle(Ayu.fgMuted)
            }
            .padding(.bottom, Spacing.md)
        }
    }

    // MARK: - Gauge Section

    private var gaugeSection: some View {
        HeroGauge(
            genreCoverage: viewModel.metrics.genreCoverage,
            yearCoverage: viewModel.metrics.yearCoverage,
            consistencyCoverage: viewModel.metrics.consistencyCoverage,
            trackCount: viewModel.metrics.totalTracks,
            onArcTapped: { layer in
                switch layer {
                case .genre, .year, .consistency:
                    onNavigate(.update)
                }
            },
            detailedCounts: .init(
                genre: (
                    tagged: viewModel.metrics.tracksWithGenre,
                    total: viewModel.metrics.totalTracks
                ),
                year: (
                    tagged: viewModel.metrics.tracksWithYear,
                    total: viewModel.metrics.totalTracks
                ),
                consistency: (
                    tagged: viewModel.metrics.tracksWithBoth,
                    total: viewModel.metrics.totalTracks
                )
            ),
            animateEntrance: animateGaugeEntrance
        )
        .frame(width: 300, height: 180)
        .frame(maxWidth: .infinity)
        .padding(.bottom, Spacing.xxxl)
    }

    // MARK: - Metrics Section

    private var metricsSection: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 180, maximum: 280))],
            spacing: Spacing.md
        ) {
            MetricCard(
                label: "Need Genre",
                value: viewModel.metrics.tracksNeedingGenre.formatted(),
                icon: "tag.fill",
                tint: Ayu.purple,
                trend: viewModel.genreTrend,
                trendDelta: viewModel.genreTrendDelta
            ) {
                onNavigate(.update)
            }

            MetricCard(
                label: "Need Year",
                value: viewModel.metrics.tracksNeedingYear.formatted(),
                icon: "calendar.badge.exclamationmark",
                tint: Ayu.info,
                trend: viewModel.yearTrend,
                trendDelta: viewModel.yearTrendDelta
            ) {
                onNavigate(.update)
            }

            MetricCard(
                label: "Recently Added",
                value: viewModel.metrics.recentlyAdded.formatted(),
                icon: "clock.arrow.circlepath",
                tint: Ayu.success,
                trend: viewModel.recentTrend,
                trendDelta: viewModel.recentTrendDelta
            ) {
                onNavigate(.browse)
            }
        }
        .padding(.bottom, Spacing.xxl)
    }

    // MARK: - Quick Actions Section

    private var quickActionsSection: some View {
        VStack(spacing: Spacing.xs) {
            QuickActionButton(
                category: "Genre",
                untaggedCount: viewModel.metrics.tracksNeedingGenre,
                icon: "tag.fill",
                tint: Ayu.purple
            ) {
                onNavigate(.update)
            }

            QuickActionButton(
                category: "Year",
                untaggedCount: viewModel.metrics.tracksNeedingYear,
                icon: "calendar",
                tint: Ayu.info
            ) {
                onNavigate(.update)
            }
        }
        .padding(.bottom, Spacing.xxl)
    }

    // MARK: - Timestamp Footer

    @ViewBuilder
    private var timestampFooter: some View {
        if case let .cached(lastUpdated) = viewModel.loadingState {
            HStack {
                Spacer()
                Text("Updated \(lastUpdated, format: .relative(presentation: .named))")
                    .font(AppFont.caption)
                    .foregroundStyle(Ayu.fgMuted)
                Spacer()
            }
        }
    }

    // MARK: - Shimmer Content

    private var shimmerContent: some View {
        VStack(spacing: 0) {
            // Match real gaugeSection: 300x180 frame + xxxl bottom padding
            ShimmerPlaceholder(shape: .gauge)
                .frame(width: 300, height: 180)
                .frame(maxWidth: .infinity)
                .padding(.bottom, Spacing.xxxl)

            // Match real metricsSection: same grid + xxl bottom padding
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 180, maximum: 280))],
                spacing: Spacing.md
            ) {
                ShimmerPlaceholder(shape: .card)
                ShimmerPlaceholder(shape: .card)
                ShimmerPlaceholder(shape: .card)
            }
            .padding(.bottom, Spacing.xxl)

            // Match real quickActionsSection: same VStack spacing + xxl bottom padding
            VStack(spacing: Spacing.xs) {
                ShimmerPlaceholder(shape: .quickAction(height: 44))
                ShimmerPlaceholder(shape: .quickAction(height: 44))
            }
            .padding(.bottom, Spacing.xxl)
        }
    }

    // MARK: - Permission Denied

    private var permissionDeniedView: some View {
        ContentUnavailableView {
            Label("Music Access Required", systemImage: "music.note.list")
        } description: {
            Text("GenreUpdater needs permission to read your Music library. Grant access in System Settings.")
        } actions: {
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Ayu.accent)
        }
    }

    // MARK: - Empty Library

    private var emptyLibraryView: some View {
        ContentUnavailableView {
            Label("Your Music Library is Empty", systemImage: "music.note")
        } description: {
            Text("Add some music to Music.app and come back -- GenreUpdater will help organize it.")
        } actions: {
            Button("Open Music") {
                if let url = URL(string: "music://") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Ayu.accent)
        }
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Something Went Wrong", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") {
                viewModel.loadCachedMetrics(from: metricsSnapshot)
            }
            .buttonStyle(.borderedProminent)
            .tint(Ayu.accent)
        }
    }
}

// MARK: - Preview

#Preview("Dashboard -- Populated") {
    DashboardView(
        tracks: PreviewData.sampleTracks,
        metricsSnapshot: nil,
        isLoadingTracks: false,
        onNavigate: { _ in }
    )
    .frame(width: 700, height: 800)
}

#Preview("Dashboard -- Shimmer") {
    DashboardView(
        tracks: [],
        metricsSnapshot: nil,
        isLoadingTracks: true,
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
