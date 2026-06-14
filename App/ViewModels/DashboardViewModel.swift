// DashboardViewModel.swift — Dashboard loading state machine with cached-first metrics and trends.

import Core
import Foundation
import Services
import SharedUI
import SwiftUI

// MARK: - Dashboard Loading State

/// Models the Dashboard's data lifecycle from first-launch shimmer through live data display.
enum DashboardLoadingState: Equatable {
    /// First launch, no cache — show shimmer placeholders.
    case shimmer
    /// Showing cached data from a previous scan.
    case cached(lastUpdated: Date)
    /// Live scan in progress.
    case updating
    /// Showing live data from a completed scan.
    case live
    /// Scan failed with an error message.
    case error(String)
    /// MusicKit access denied by user.
    case permissionDenied
    /// Library has 0 tracks in Music.app.
    case emptyLibrary
}

// MARK: - Dashboard Metrics

/// Aggregated library health metrics for display.
struct DashboardMetrics: Equatable {
    let totalTracks: Int
    let tracksWithGenre: Int
    let tracksWithYear: Int
    let tracksWithBoth: Int
    let tracksNeedingGenre: Int
    let tracksNeedingYear: Int
    let recentlyAdded: Int
    let genreCoverage: Double
    let yearCoverage: Double
    let consistencyCoverage: Double

    static let empty = Self(
        totalTracks: 0,
        tracksWithGenre: 0,
        tracksWithYear: 0,
        tracksWithBoth: 0,
        tracksNeedingGenre: 0,
        tracksNeedingYear: 0,
        recentlyAdded: 0,
        genreCoverage: 0,
        yearCoverage: 0,
        consistencyCoverage: 0
    )
}

// MARK: - Trend Direction

/// Directional trend indicator for metric cards.
enum TrendDirection {
    case up
    case down
    case flat

    var icon: String {
        switch self {
        case .up: "arrow.up.right"
        case .down: "arrow.down.right"
        case .flat: "arrow.right"
        }
    }

    var tint: Color {
        switch self {
        case .up: Ayu.success
        case .down: Ayu.error
        case .flat: Ayu.fgSecondary
        }
    }
}

// MARK: - Dashboard View Model

/// Two-phase cached-first loading ViewModel with trend calculations.
///
/// On launch, loads cached metrics from `PersistedMetricsSnapshot` for
/// instant display, then refreshes from live MusicKit data. Computes
/// trend direction by comparing current metrics to previous scan values.
@Observable @MainActor
final class DashboardViewModel {
    private let loadingTimeoutDuration: Duration

    init(loadingTimeoutDuration: Duration = .seconds(15)) {
        self.loadingTimeoutDuration = loadingTimeoutDuration
    }

    // MARK: - Published State

    private(set) var loadingState: DashboardLoadingState = .shimmer
    private(set) var metrics: DashboardMetrics = .empty
    private(set) var snapshot: LibraryDashboardSnapshot = .empty
    private(set) var previousMetrics: DashboardMetrics?
    private(set) var isFirstLoad = true

    // MARK: - Shimmer Timing

    private var shimmerStartTime: Date?
    private var loadingTimeoutTask: Task<Void, Never>?

    // MARK: - Computed View State

    /// Whether shimmer placeholders should be visible.
    var showShimmer: Bool {
        loadingState == .shimmer
    }

    /// Whether live/cached content should be visible.
    var showLiveContent: Bool {
        switch loadingState {
        case .cached, .updating, .live:
            true
        default:
            false
        }
    }

    /// Whether an error state should be visible.
    var showError: Bool {
        switch loadingState {
        case .error, .permissionDenied, .emptyLibrary:
            true
        default:
            false
        }
    }

    // MARK: - Cached-First Loading

    /// Phase 1: Load cached metrics snapshot for instant display.
    ///
    /// If no snapshot exists (first launch), sets shimmer state.
    /// Otherwise builds metrics from the snapshot and loads previous
    /// scan values for trend calculation.
    func loadCachedMetrics(from snapshot: PersistedMetricsSnapshot?) {
        guard let snapshot else {
            loadingState = .shimmer
            shimmerStartTime = Date()
            startLoadingTimeout()
            return
        }

        metrics = DashboardMetrics(
            totalTracks: snapshot.totalTracks,
            tracksWithGenre: snapshot.tracksWithGenre,
            tracksWithYear: snapshot.tracksWithYear,
            tracksWithBoth: snapshot.tracksWithBoth,
            tracksNeedingGenre: snapshot.tracksNeedingGenre,
            tracksNeedingYear: snapshot.tracksNeedingYear,
            recentlyAdded: snapshot.recentlyAdded,
            genreCoverage: snapshot.genreCoverage,
            yearCoverage: snapshot.yearCoverage,
            consistencyCoverage: snapshot.consistencyCoverage
        )

        // Build previous metrics from snapshot's stored baseline
        if snapshot.previousTotalTracks > 0 {
            previousMetrics = DashboardMetrics(
                totalTracks: snapshot.previousTotalTracks,
                tracksWithGenre: 0,
                tracksWithYear: 0,
                tracksWithBoth: 0,
                tracksNeedingGenre: snapshot.previousTracksNeedingGenre,
                tracksNeedingYear: snapshot.previousTracksNeedingYear,
                recentlyAdded: snapshot.previousRecentlyAdded,
                genreCoverage: 0,
                yearCoverage: 0,
                consistencyCoverage: 0
            )
        }

        loadingState = .cached(lastUpdated: snapshot.timestamp)
        startLoadingTimeout()
    }

    /// Phase 2: Refresh metrics from live MusicKit track data.
    ///
    /// Computes all metrics in a single O(n) pass. Saves current metrics
    /// as previous for trend calculation if they contain real data.
    /// The `isLoadingTracks` guard prevents transitioning to `.emptyLibrary`
    /// while MusicKit is still fetching (core bug fix for first-launch flash).
    func refreshFromLive(
        tracks: [Track],
        isLoadingTracks: Bool,
        loadError: LibraryLoadError? = nil
    ) {
        if let loadError {
            applyLoadError(loadError)
            return
        }

        // Core bug fix: don't transition to emptyLibrary while still loading
        guard !isLoadingTracks || !tracks.isEmpty else {
            transitionStaleErrorToLoading()
            return
        }

        guard !tracks.isEmpty else {
            loadingState = .emptyLibrary
            loadingTimeoutTask?.cancel()
            return
        }

        // Save current as previous if it has real data
        if metrics.totalTracks > 0 {
            previousMetrics = metrics
        }

        metrics = makeMetrics(from: tracks)

        loadingTimeoutTask?.cancel()

        // Enforce minimum shimmer hold time before transitioning to live
        if loadingState == .shimmer, let startTime = shimmerStartTime {
            let elapsed = Date().timeIntervalSince(startTime)
            let remainingHold = max(0, 0.5 - elapsed)
            if remainingHold > 0 {
                Task {
                    try? await Task.sleep(for: .seconds(remainingHold))
                    transitionToLive()
                }
                return
            }
        }

        transitionToLive()
    }

    // swiftlint:disable:next function_parameter_count
    func refreshSnapshot(
        tracks: [Track],
        metricsSnapshot: PersistedMetricsSnapshot? = nil,
        lastScanDate: Date?,
        isLoadingTracks: Bool,
        loadError: LibraryLoadError?,
        isDryRun: Bool,
        workflowState: WorkflowDashboardState
    ) {
        if let loadError {
            applyLoadError(loadError)
        }

        if tracks.isEmpty, isLoadingTracks, loadError == nil, let metricsSnapshot {
            loadCachedMetrics(from: metricsSnapshot)
            snapshot = LibraryDashboardSnapshot.make(
                persistedMetrics: metricsSnapshot,
                isLoading: isLoadingTracks,
                loadError: loadError,
                isDryRun: isDryRun,
                workflow: workflowState
            )
            return
        }

        if tracks.isEmpty, isLoadingTracks, loadError == nil {
            loadCachedMetrics(from: nil)
        }

        if tracks.isEmpty, !isLoadingTracks, loadError == nil {
            loadingTimeoutTask?.cancel()
            loadingState = .emptyLibrary
        }

        snapshot = LibraryDashboardSnapshot.make(
            tracks: tracks,
            lastScanDate: lastScanDate,
            isLoading: isLoadingTracks,
            loadError: loadError,
            isDryRun: isDryRun,
            workflow: workflowState
        )
    }

    /// Set the permission denied state.
    func setPermissionDenied() {
        loadingTimeoutTask?.cancel()
        loadingState = .permissionDenied
        snapshot = LibraryDashboardSnapshot.make(
            tracks: [],
            lastScanDate: nil,
            isLoading: false,
            loadError: .permissionDenied,
            isDryRun: true,
            workflow: .empty
        )
    }

    /// Set the error state with a message.
    func setError(_ message: String) {
        loadingTimeoutTask?.cancel()
        loadingState = .error(message)
        snapshot = LibraryDashboardSnapshot.make(
            tracks: [],
            lastScanDate: nil,
            isLoading: false,
            loadError: .failed(message),
            isDryRun: true,
            workflow: .empty
        )
    }

    // MARK: - Transition Helpers

    /// Transition from shimmer to live state.
    ///
    /// Does NOT clear `isFirstLoad` here -- DashboardView reads the flag
    /// during its stagger cascade and clears it afterwards. Clearing it
    /// in the same transaction as `loadingState` change would prevent
    /// the onChange handler from seeing the true value.
    private func transitionToLive() {
        loadingState = .live
    }

    private func transitionStaleErrorToLoading() {
        switch loadingState {
        case .error, .permissionDenied:
            if metrics.totalTracks > 0 {
                loadingState = .updating
                shimmerStartTime = Date()
                startLoadingTimeout()
            } else {
                loadingState = .shimmer
                shimmerStartTime = Date()
                startLoadingTimeout()
            }

            snapshot = LibraryDashboardSnapshot.make(
                tracks: [],
                lastScanDate: nil,
                isLoading: true,
                loadError: nil,
                isDryRun: true,
                workflow: .empty
            )
        default:
            break
        }
    }

    /// Mark the initial data load as complete.
    ///
    /// Called by DashboardView after the entrance stagger has been evaluated,
    /// so `isFirstLoad` is still `true` when the content visibility transition fires.
    func markFirstLoadComplete() {
        isFirstLoad = false
    }

    /// Start a loading timeout that shows an error if
    /// live Music data remains unavailable.
    private func startLoadingTimeout() {
        loadingTimeoutTask?.cancel()
        loadingTimeoutTask = Task {
            do {
                try await Task.sleep(for: loadingTimeoutDuration)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            if shouldFailLoadingTimeout {
                setError("Loading timed out. Please check your Music library access and try again.")
            }
        }
    }

    // MARK: - Private

    func applyLoadError(_ loadError: LibraryLoadError) {
        switch loadError {
        case .permissionDenied:
            setPermissionDenied()
        case .restricted:
            setError(loadError.message)
        case let .failed(message):
            setError(message)
        }
    }

    private var shouldFailLoadingTimeout: Bool {
        switch loadingState {
        case .shimmer, .cached, .updating:
            true
        case .live, .error, .permissionDenied, .emptyLibrary:
            false
        }
    }

    private func makeMetrics(from tracks: [Track]) -> DashboardMetrics {
        let total = tracks.count
        var genreCount = 0
        var yearCount = 0
        var bothCount = 0
        var recentCount = 0
        let sevenDaysAgo = Calendar.current.date(
            byAdding: .day,
            value: -7,
            to: .now
        )

        for track in tracks {
            let hasGenre = GenreUtilities.hasPresentGenre(track.genre)
            let hasYear = track.year != nil

            if hasGenre { genreCount += 1 }
            if hasYear { yearCount += 1 }
            if hasGenre, hasYear { bothCount += 1 }

            if let dateAdded = track.dateAdded,
               let cutoff = sevenDaysAgo,
               dateAdded >= cutoff {
                recentCount += 1
            }
        }

        return DashboardMetrics(
            totalTracks: total,
            tracksWithGenre: genreCount,
            tracksWithYear: yearCount,
            tracksWithBoth: bothCount,
            tracksNeedingGenre: total - genreCount,
            tracksNeedingYear: total - yearCount,
            recentlyAdded: recentCount,
            genreCoverage: Double(genreCount) / Double(total),
            yearCoverage: Double(yearCount) / Double(total),
            consistencyCoverage: Double(bothCount) / Double(total)
        )
    }
}

// MARK: - Trend Calculations

extension DashboardViewModel {
    /// Genre trend: fewer tracks needing genre is good (down).
    var genreTrend: TrendDirection? {
        guard let previous = previousMetrics else { return nil }
        return trendForDecreasing(
            current: metrics.tracksNeedingGenre,
            previous: previous.tracksNeedingGenre
        )
    }

    /// Year trend: fewer tracks needing year is good (down).
    var yearTrend: TrendDirection? {
        guard let previous = previousMetrics else { return nil }
        return trendForDecreasing(
            current: metrics.tracksNeedingYear,
            previous: previous.tracksNeedingYear
        )
    }

    /// Recently added trend: more is neutral/positive (up).
    var recentTrend: TrendDirection? {
        guard let previous = previousMetrics else { return nil }
        let current = metrics.recentlyAdded
        let prev = previous.recentlyAdded
        if current > prev { return .up }
        if current < prev { return .down }
        return .flat
    }

    /// Delta for genre trend (positive = more needing, negative = fewer needing).
    var genreTrendDelta: Int? {
        guard let previous = previousMetrics else { return nil }
        return metrics.tracksNeedingGenre - previous.tracksNeedingGenre
    }

    /// Delta for year trend.
    var yearTrendDelta: Int? {
        guard let previous = previousMetrics else { return nil }
        return metrics.tracksNeedingYear - previous.tracksNeedingYear
    }

    /// Delta for recently added trend.
    var recentTrendDelta: Int? {
        guard let previous = previousMetrics else { return nil }
        return metrics.recentlyAdded - previous.recentlyAdded
    }

    /// Trend for metrics where decrease is good (fewer tracks needing attention).
    private func trendForDecreasing(current: Int, previous: Int) -> TrendDirection {
        if current < previous { return .down }
        if current > previous { return .up }
        return .flat
    }
}
