// swiftlint:disable file_length
// DashboardView.swift — Library health dashboard with cached-first metrics.

import AppKit
import Core
import Services
import SharedUI
import SwiftUI

// MARK: - Dashboard View

/// Snapshot-driven dashboard showing whether the library is safe to update.
///
/// Uses a two-phase cached-first loading pattern: MainView passes persisted metrics
/// instantly, then the dashboard refreshes from live MusicKit data when tracks arrive.
/// First launch shows full shimmer placeholders; subsequent launches never show "0 tracks".
struct DashboardView: View {
    @State private var viewModel = DashboardViewModel()
    @State private var showHero = false
    @State private var showStatus = false
    @State private var showLowerSections = false
    @State private var animateHealthEntrance = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionScale) private var motionScale

    let tracks: [Track]
    let metricsSnapshot: PersistedMetricsSnapshot?
    let isLoadingTracks: Bool
    let loadError: LibraryLoadError?
    let lastScanDate: Date?
    let isDryRun: Bool
    let workflowState: WorkflowDashboardState
    let onScanNow: () -> Void
    let onReviewChanges: () -> Void

    private var snapshot: LibraryDashboardSnapshot {
        viewModel.snapshot
    }

    private var showsDashboardContent: Bool {
        !viewModel.showShimmer
    }

    private var isPrimaryActionDisabled: Bool {
        if case .loading = snapshot.scanState {
            return true
        }
        if case .writing = snapshot.writeState {
            return true
        }
        return false
    }

    private var isScanActionDisabled: Bool {
        if case .loading = snapshot.scanState {
            return true
        }
        return false
    }

    private var snapshotRefreshKey: DashboardSnapshotRefreshKey {
        DashboardSnapshotRefreshKey(
            trackCount: tracks.count,
            trackContentFingerprint: .make(from: tracks),
            metricsSnapshotFingerprint: .make(from: metricsSnapshot),
            isLoadingTracks: isLoadingTracks,
            loadErrorKey: loadError?.dashboardRefreshKey,
            lastScanDate: lastScanDate,
            isDryRun: isDryRun,
            proposedChangeCount: workflowState.proposedChangeCount,
            acceptedChangeCount: workflowState.acceptedChangeCount,
            failedWriteCount: workflowState.failedWriteCount,
            isProcessing: workflowState.isProcessing,
            phaseLabel: workflowState.phaseLabel
        )
    }

    var body: some View {
        ScrollView {
            ZStack {
                if viewModel.showShimmer {
                    shimmerContent
                        .transition(.opacity)
                } else {
                    liveContent
                        .transition(.opacity)
                }
            }
            .animation(Motion.curveCrossfade, value: viewModel.showShimmer)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.xxl)
        }
        .task(id: snapshotRefreshKey) {
            viewModel.refreshFromLive(
                tracks: tracks,
                isLoadingTracks: isLoadingTracks,
                loadError: loadError
            )
            viewModel.refreshSnapshot(
                tracks: tracks,
                metricsSnapshot: metricsSnapshot,
                lastScanDate: lastScanDate,
                isLoadingTracks: isLoadingTracks,
                loadError: loadError,
                isDryRun: isDryRun,
                workflowState: workflowState
            )
        }
        .onChange(of: showsDashboardContent) { _, isVisible in
            guard isVisible else { return }
            let isFirstLoad = viewModel.isFirstLoad
            viewModel.markFirstLoadComplete()

            if reduceMotion || !isFirstLoad {
                showHero = true
                showStatus = true
                showLowerSections = true
            } else {
                animateHealthEntrance = true
                let stagger = Motion.scaled(Motion.curveAppear, by: motionScale)
                withAnimation(stagger) { showHero = true }
                withAnimation(stagger.delay(0.05)) { showStatus = true }
                withAnimation(stagger.delay(0.10)) { showLowerSections = true }
            }
        }
    }

    @ViewBuilder
    private var liveContent: some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: Spacing.md) {
                liveStack
            }
        } else {
            liveStack
        }
        #else
        liveStack
        #endif
    }

    private var liveStack: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            DashboardHeader(
                snapshot: snapshot,
                isPrimaryActionDisabled: isPrimaryActionDisabled,
                isScanActionDisabled: isScanActionDisabled,
                onScanNow: onScanNow,
                onPrimaryAction: performPrimaryAction
            )

            DashboardHealthHero(
                snapshot: snapshot,
                animateEntrance: animateHealthEntrance,
                onArcTapped: performReviewAction
            )
            .opacity(showHero ? 1 : 0)

            DashboardMetricCards(
                snapshot: snapshot,
                genreTrend: viewModel.genreTrend,
                genreTrendDelta: viewModel.genreTrendDelta,
                yearTrend: viewModel.yearTrend,
                yearTrendDelta: viewModel.yearTrendDelta,
                isEnabled: snapshot.allowsReviewActions,
                onReviewChanges: performReviewAction
            )
            .opacity(showStatus ? 1 : 0)

            DashboardQuickActions(
                snapshot: snapshot,
                isDisabled: !snapshot.allowsReviewActions,
                onReviewChanges: performReviewAction
            )
            .opacity(showStatus ? 1 : 0)

            DashboardPipelineStrip(snapshot: snapshot)
                .opacity(showStatus ? 1 : 0)

            DashboardLowerGrid(snapshot: snapshot)
                .opacity(showLowerSections ? 1 : 0)

            timestampFooter
                .opacity(showLowerSections ? 1 : 0)
        }
    }

    private var shimmerContent: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        ShimmerPlaceholder(shape: .rectangle(width: 180, height: 22))
                        ShimmerPlaceholder(shape: .rectangle(width: 320, height: 14))
                    }
                    Spacer(minLength: Spacing.xl)
                    HStack(spacing: Spacing.sm) {
                        ShimmerPlaceholder(shape: .rectangle(width: 104, height: 32))
                        ShimmerPlaceholder(shape: .rectangle(width: 148, height: 32))
                    }
                }

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    ShimmerPlaceholder(shape: .rectangle(width: 180, height: 22))
                    ShimmerPlaceholder(shape: .rectangle(width: 320, height: 14))
                    ShimmerPlaceholder(shape: .rectangle(width: 148, height: 32))
                }
            }
            .padding(.bottom, Spacing.xs)

            ShimmerPlaceholder(shape: .quickAction(height: 300))
                .dashboardGlassSurface(cornerRadius: Radius.xl)

            ShimmerPlaceholder(shape: .quickAction(height: 78))
                .dashboardGlassSurface(cornerRadius: Radius.lg)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 280), spacing: Spacing.md)],
                spacing: Spacing.md
            ) {
                ShimmerPlaceholder(shape: .quickAction(height: 220))
                    .dashboardGlassSurface(cornerRadius: Radius.lg)
                ShimmerPlaceholder(shape: .quickAction(height: 220))
                    .dashboardGlassSurface(cornerRadius: Radius.lg)
                ShimmerPlaceholder(shape: .quickAction(height: 220))
                    .dashboardGlassSurface(cornerRadius: Radius.lg)
            }
        }
    }

    @ViewBuilder
    private var timestampFooter: some View {
        if case let .cached(lastUpdated) = viewModel.loadingState {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "clock")
                Text("Updated \(lastUpdated, format: .relative(presentation: .named))")
            }
            .font(AppFont.caption)
            .foregroundStyle(Ayu.fgMuted)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, Spacing.xs)
        }
    }

    private func performPrimaryAction() {
        switch snapshot.scanState {
        case .loading:
            return
        case .permissionDenied:
            openSystemSettings()
        case .failed, .empty:
            onScanNow()
        case .ready:
            performReviewAction()
        }
    }

    private func performReviewAction() {
        guard snapshot.allowsReviewActions else {
            return
        }
        onReviewChanges()
    }

    private func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Media") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

private struct DashboardHeader: View {
    let snapshot: LibraryDashboardSnapshot
    let isPrimaryActionDisabled: Bool
    let isScanActionDisabled: Bool
    let onScanNow: () -> Void
    let onPrimaryAction: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Spacing.xl) {
                titleBlock
                Spacer(minLength: Spacing.xl)
                actionButtons
            }

            VStack(alignment: .leading, spacing: Spacing.md) {
                titleBlock
                actionButtons
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, Spacing.xs)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Library Health")
                .font(AppFont.headline)
                .foregroundStyle(Ayu.fgPrimary)
            Text(snapshot.primaryStatusText)
                .font(AppFont.body)
                .foregroundStyle(Ayu.fgSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actionButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.sm) {
                scanButton
                primaryButton
            }

            VStack(alignment: .leading, spacing: Spacing.sm) {
                scanButton
                primaryButton
            }
        }
    }

    private var scanButton: some View {
        Button(action: onScanNow) {
            Label("Scan now", systemImage: "arrow.clockwise")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .frame(minWidth: 120)
        .disabled(isScanActionDisabled)
    }

    private var primaryButton: some View {
        Button(action: onPrimaryAction) {
            Label(snapshot.primaryActionTitle, systemImage: snapshot.primaryActionIcon)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(snapshot.primaryActionTint)
        .frame(minWidth: 150)
        .disabled(isPrimaryActionDisabled)
    }
}

private struct DashboardHealthHero: View {
    let snapshot: LibraryDashboardSnapshot
    let animateEntrance: Bool
    let onArcTapped: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Spacing.xxl) {
                heroCopy
                Spacer(minLength: Spacing.xl)
                heroGauge
            }

            VStack(alignment: .leading, spacing: Spacing.xl) {
                heroCopy
                heroGauge
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardGlassSurface(cornerRadius: Radius.xl)
    }

    private var heroCopy: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Label(snapshot.safetySummary, systemImage: snapshot.safetyIcon)
                .font(AppFont.subheadline)
                .foregroundStyle(snapshot.healthTint)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(snapshot.healthPercentage)% library health")
                .font(AppFont.metricSmall)
                .foregroundStyle(Ayu.fgPrimary)
                .contentTransition(.numericText())
                .fixedSize(horizontal: false, vertical: true)

            Text(snapshot.primaryStatusText)
                .font(AppFont.body)
                .foregroundStyle(Ayu.fgSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(snapshot.scanContextText)
                .font(AppFont.body)
                .foregroundStyle(Ayu.fgSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 460, alignment: .leading)
    }

    private var heroGauge: some View {
        HeroGauge(
            genreCoverage: snapshot.genreCoverageRatio,
            yearCoverage: snapshot.yearCoverageRatio,
            consistencyCoverage: snapshot.consistencyCoverageRatio,
            trackCount: snapshot.totalTracks,
            onArcTapped: { _ in onArcTapped() },
            detailedCounts: HeroGauge.DetailedCounts(
                genre: (tagged: snapshot.tracksWithGenre, total: snapshot.totalTracks),
                year: (tagged: snapshot.tracksWithYear, total: snapshot.totalTracks),
                consistency: (tagged: snapshot.tracksWithBoth, total: snapshot.totalTracks)
            ),
            animateEntrance: animateEntrance
        )
        .frame(minWidth: 240, idealWidth: 300, maxWidth: 340, minHeight: 170, idealHeight: 190, maxHeight: 220)
    }
}

private struct DashboardMetricCards: View {
    let snapshot: LibraryDashboardSnapshot
    let genreTrend: TrendDirection?
    let genreTrendDelta: Int?
    let yearTrend: TrendDirection?
    let yearTrendDelta: Int?
    let isEnabled: Bool
    let onReviewChanges: () -> Void

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 180, maximum: 280), spacing: Spacing.md)]
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.md) {
            MetricCard(
                label: "Missing Genres",
                value: snapshot.missingGenreCount.formatted(),
                icon: "tag.slash",
                tint: snapshot.missingGenreCount > 0 ? Ayu.warning : Ayu.success,
                trend: genreTrend,
                trendDelta: genreTrendDelta,
                isEnabled: isEnabled,
                onTap: onReviewChanges
            )

            MetricCard(
                label: "Missing Years",
                value: snapshot.missingYearCount.formatted(),
                icon: "calendar.badge.exclamationmark",
                tint: snapshot.missingYearCount > 0 ? Ayu.info : Ayu.success,
                trend: yearTrend,
                trendDelta: yearTrendDelta,
                isEnabled: isEnabled,
                onTap: onReviewChanges
            )

            MetricCard(
                label: "Complete Metadata",
                value: snapshot.tracksWithBoth.formatted(),
                icon: "checkmark.seal",
                tint: Ayu.success,
                trend: nil,
                trendDelta: nil,
                isEnabled: isEnabled,
                onTap: onReviewChanges
            )
        }
    }
}

private struct DashboardQuickActions: View {
    let snapshot: LibraryDashboardSnapshot
    let isDisabled: Bool
    let onReviewChanges: () -> Void

    var body: some View {
        VStack(spacing: Spacing.xs) {
            QuickActionButton(
                category: "Genre",
                untaggedCount: snapshot.missingGenreCount,
                icon: "tag.fill",
                tint: Ayu.purple,
                action: onReviewChanges
            )

            QuickActionButton(
                category: "Year",
                untaggedCount: snapshot.missingYearCount,
                icon: "calendar",
                tint: Ayu.info,
                action: onReviewChanges
            )
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardGlassSurface(cornerRadius: Radius.lg)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.65 : 1)
    }
}

private struct DashboardPipelineStrip: View {
    let snapshot: LibraryDashboardSnapshot

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.lg) {
                DashboardStatusItem(
                    title: "Scan",
                    value: snapshot.scanPipelineText,
                    icon: snapshot.scanPipelineIcon,
                    tint: snapshot.scanPipelineTint
                )
                Divider()
                DashboardStatusItem(
                    title: "Write",
                    value: snapshot.writePipelineText,
                    icon: snapshot.writePipelineIcon,
                    tint: snapshot.writePipelineTint
                )
            }

            VStack(alignment: .leading, spacing: Spacing.md) {
                DashboardStatusItem(
                    title: "Scan",
                    value: snapshot.scanPipelineText,
                    icon: snapshot.scanPipelineIcon,
                    tint: snapshot.scanPipelineTint
                )
                Divider()
                DashboardStatusItem(
                    title: "Write",
                    value: snapshot.writePipelineText,
                    icon: snapshot.writePipelineIcon,
                    tint: snapshot.writePipelineTint
                )
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardGlassSurface(cornerRadius: Radius.lg)
    }
}

private struct DashboardStatusItem: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(AppFont.caption)
                    .foregroundStyle(Ayu.fgMuted)
                Text(value)
                    .font(AppFont.subheadline)
                    .foregroundStyle(Ayu.fgPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DashboardLowerGrid: View {
    let snapshot: LibraryDashboardSnapshot

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 280), spacing: Spacing.md)]
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.md) {
            DashboardCoverageSection(buckets: snapshot.coverageBuckets)
            DashboardIssuesSection(issues: snapshot.issues)
            DashboardActivitySection(activities: snapshot.recentActivity)
        }
    }
}

private struct DashboardInfoSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Label(title, systemImage: icon)
                .font(AppFont.subheadline)
                .foregroundStyle(Ayu.fgPrimary)

            content

            Spacer(minLength: 0)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        .dashboardGlassSurface(cornerRadius: Radius.lg)
    }
}

private struct DashboardCoverageSection: View {
    let buckets: [DashboardCoverageBucket]

    var body: some View {
        DashboardInfoSection(title: "Coverage", icon: "chart.bar.fill") {
            VStack(alignment: .leading, spacing: Spacing.md) {
                ForEach(buckets) { bucket in
                    DashboardCoverageRow(bucket: bucket)
                }
            }
        }
    }
}

private struct DashboardCoverageRow: View {
    let bucket: DashboardCoverageBucket

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(bucket.title)
                    .font(AppFont.caption)
                    .foregroundStyle(Ayu.fgSecondary)
                Spacer(minLength: Spacing.sm)
                Text(DashboardFormat.percent(bucket.ratio))
                    .font(AppFont.caption.bold())
                    .foregroundStyle(Ayu.fgPrimary)
                    .monospacedDigit()
            }

            ProgressView(value: bucket.ratio)
                .tint(bucket.tint)
        }
    }
}

private struct DashboardIssuesSection: View {
    let issues: [DashboardIssue]

    var body: some View {
        DashboardInfoSection(title: "Needs Attention", icon: "exclamationmark.triangle.fill") {
            VStack(alignment: .leading, spacing: Spacing.md) {
                ForEach(issues) { issue in
                    DashboardIssueRow(issue: issue)
                }
            }
        }
    }
}

private struct DashboardIssueRow: View {
    let issue: DashboardIssue

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: issue.severity.icon)
                .foregroundStyle(issue.rowTint)
                .frame(width: 20)

            Text(issue.title)
                .font(AppFont.caption)
                .foregroundStyle(Ayu.fgSecondary)

            Spacer(minLength: Spacing.sm)

            Text(issue.count.formatted())
                .font(AppFont.caption.bold())
                .foregroundStyle(issue.rowTint)
                .monospacedDigit()
        }
    }
}

private struct DashboardActivitySection: View {
    let activities: [DashboardActivity]

    var body: some View {
        DashboardInfoSection(title: "Recent Activity", icon: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: Spacing.md) {
                ForEach(activities) { activity in
                    DashboardActivityRow(activity: activity)
                }
            }
        }
    }
}

private struct DashboardActivityRow: View {
    let activity: DashboardActivity

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(Ayu.accent)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(activity.title)
                    .font(AppFont.caption.bold())
                    .foregroundStyle(Ayu.fgPrimary)
                Text(activity.detail)
                    .font(AppFont.caption)
                    .foregroundStyle(Ayu.fgSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private enum DashboardFormat {
    static func percent(_ ratio: Double) -> String {
        "\(Int((min(max(ratio, 0), 1) * 100).rounded()))%"
    }
}

extension LibraryDashboardSnapshot {
    fileprivate var safetySummary: String {
        switch scanState {
        case .loading:
            return "Checking update safety"
        case .permissionDenied:
            return "Access required before updates"
        case .failed:
            return "Scan required before updates"
        case .empty:
            return "No tracks to update"
        case .ready:
            break
        }

        switch writeState {
        case .writing:
            return "Writing updates now"
        case .blocked:
            return "Review errors before updating"
        case .dryRun, .ready:
            if hasBlockingIssues {
                return "Review blocked items first"
            }
            if readyUpdateCount > 0 {
                return "Safe to review updates"
            }
            return "Safe with no updates queued"
        }
    }

    fileprivate var scanContextText: String {
        switch scanState {
        case .loading:
            return "Music library scan is running."
        case .permissionDenied:
            return "Music access is required before GenreUpdater can evaluate the library."
        case let .failed(message):
            return message
        case .empty:
            return "Add tracks to Music and scan again."
        case .ready:
            if hasBlockingIssues {
                return "Resolve protected files or write errors before applying changes."
            }
            if readyUpdateCount > 0 {
                return "Accepted changes are ready for review."
            }
            return "No blocking write issues were found."
        }
    }

    fileprivate var safetyIcon: String {
        switch scanState {
        case .loading:
            "arrow.triangle.2.circlepath"
        case .permissionDenied:
            "lock.fill"
        case .failed:
            "xmark.octagon.fill"
        case .empty:
            "music.note"
        case .ready:
            hasBlockingIssues ? "exclamationmark.triangle.fill" : "checkmark.seal.fill"
        }
    }

    fileprivate var primaryActionIcon: String {
        switch scanState {
        case .loading:
            "arrow.clockwise"
        case .permissionDenied:
            "lock.open"
        case .failed:
            "arrow.clockwise"
        case .empty:
            "magnifyingglass"
        case .ready:
            switch writeState {
            case .writing:
                "pencil"
            case .blocked:
                "exclamationmark.triangle"
            case .dryRun, .ready:
                "list.bullet.clipboard"
            }
        }
    }

    fileprivate var primaryActionTint: Color {
        switch scanState {
        case .permissionDenied, .failed:
            Ayu.warning
        case .loading:
            Ayu.info
        case .empty:
            Ayu.accent
        case .ready:
            switch writeState {
            case .blocked:
                Ayu.warning
            case .writing:
                Ayu.fgMuted
            case .dryRun, .ready:
                Ayu.accent
            }
        }
    }

    fileprivate var healthTint: Color {
        switch scanState {
        case .permissionDenied, .failed:
            return Ayu.error
        case .loading:
            return Ayu.info
        case .empty:
            return Ayu.fgMuted
        case .ready:
            break
        }

        if hasBlockingIssues {
            return Ayu.warning
        }

        switch healthScore {
        case 0.85 ... 1:
            return Ayu.success
        case 0.65 ..< 0.85:
            return Ayu.accent
        case 0.4 ..< 0.65:
            return Ayu.warning
        default:
            return Ayu.error
        }
    }

    fileprivate var scanPipelineText: String {
        switch scanState {
        case .loading:
            return "Scanning"
        case .permissionDenied:
            return "Permission needed"
        case let .failed(message):
            return message
        case .empty:
            return "No tracks found"
        case let .ready(lastScanDate):
            if let lastScanDate {
                return "Ready, \(lastScanDate.formatted(.relative(presentation: .named)))"
            }
            return "Ready"
        }
    }

    fileprivate var scanPipelineIcon: String {
        switch scanState {
        case .loading:
            "arrow.triangle.2.circlepath"
        case .permissionDenied:
            "lock.fill"
        case .failed:
            "xmark.octagon.fill"
        case .empty:
            "music.note"
        case .ready:
            "checkmark.circle.fill"
        }
    }

    fileprivate var scanPipelineTint: Color {
        switch scanState {
        case .loading:
            Ayu.info
        case .permissionDenied, .failed:
            Ayu.error
        case .empty:
            Ayu.warning
        case .ready:
            Ayu.success
        }
    }

    fileprivate var writePipelineText: String {
        switch writeState {
        case .dryRun:
            return "Dry run active"
        case let .ready(updateCount, isDryRun):
            guard updateCount >= 1 else { return "No updates queued" }
            return isDryRun ? "\(updateCount) ready for review" : "\(updateCount) ready to write"
        case let .writing(label):
            return label.isEmpty ? "Writing" : label
        case let .blocked(message):
            return message
        }
    }

    fileprivate var writePipelineIcon: String {
        switch writeState {
        case .dryRun:
            "eye.fill"
        case let .ready(updateCount, _):
            updateCount >= 1 ? "checklist" : "checkmark.circle.fill"
        case .writing:
            "pencil"
        case .blocked:
            "exclamationmark.triangle.fill"
        }
    }

    fileprivate var writePipelineTint: Color {
        switch writeState {
        case .dryRun:
            Ayu.info
        case let .ready(updateCount, _):
            updateCount >= 1 ? Ayu.accent : Ayu.success
        case .writing:
            Ayu.info
        case .blocked:
            Ayu.error
        }
    }

    private var hasBlockingIssues: Bool {
        issues.contains { issue in
            issue.count >= 1 && issue.severity == .critical
        }
    }
}

extension DashboardCoverageBucket {
    fileprivate var tint: Color {
        switch id {
        case "genre":
            Ayu.purple
        case "year":
            Ayu.info
        case "consistency":
            Ayu.accent
        case "editable":
            Ayu.success
        default:
            Ayu.fgSecondary
        }
    }
}

extension DashboardIssue {
    fileprivate var rowTint: Color {
        guard count >= 1 else { return Ayu.success }

        switch severity {
        case .info:
            return Ayu.info
        case .warning:
            return Ayu.warning
        case .critical:
            return Ayu.error
        }
    }
}

extension DashboardIssueSeverity {
    fileprivate var icon: String {
        switch self {
        case .info:
            "info.circle"
        case .warning:
            "exclamationmark.triangle"
        case .critical:
            "xmark.octagon.fill"
        }
    }
}

extension View {
    fileprivate func dashboardGlassSurface(cornerRadius: CGFloat) -> some View {
        background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Ayu.fgPrimary.opacity(0.08), lineWidth: 1)
            }
            .ayuShadow(Shadow.subtle)
            .applyLiquidGlass(in: .rect(cornerRadius: cornerRadius))
    }
}

private struct DashboardSnapshotRefreshKey: Equatable {
    let trackCount: Int
    let trackContentFingerprint: DashboardTrackContentFingerprint
    let metricsSnapshotFingerprint: DashboardMetricsSnapshotFingerprint?
    let isLoadingTracks: Bool
    let loadErrorKey: String?
    let lastScanDate: Date?
    let isDryRun: Bool
    let proposedChangeCount: Int
    let acceptedChangeCount: Int
    let failedWriteCount: Int
    let isProcessing: Bool
    let phaseLabel: String
}

private struct DashboardMetricsSnapshotFingerprint: Equatable {
    let totalTracks: Int
    let tracksWithGenre: Int
    let tracksWithYear: Int
    let tracksWithBoth: Int
    let tracksNeedingGenre: Int
    let tracksNeedingYear: Int
    let protectedFileCount: Int?
    let recentlyAdded: Int
    let timestamp: Date

    static func make(from snapshot: PersistedMetricsSnapshot?) -> Self? {
        guard let snapshot else { return nil }
        return Self(
            totalTracks: snapshot.totalTracks,
            tracksWithGenre: snapshot.tracksWithGenre,
            tracksWithYear: snapshot.tracksWithYear,
            tracksWithBoth: snapshot.tracksWithBoth,
            tracksNeedingGenre: snapshot.tracksNeedingGenre,
            tracksNeedingYear: snapshot.tracksNeedingYear,
            protectedFileCount: snapshot.protectedFileCount,
            recentlyAdded: snapshot.recentlyAdded,
            timestamp: snapshot.timestamp
        )
    }
}

extension LibraryLoadError {
    fileprivate var dashboardRefreshKey: String {
        switch self {
        case .permissionDenied:
            "permissionDenied"
        case .restricted:
            "restricted"
        case let .failed(message):
            "failed:\(message)"
        }
    }
}

struct DashboardTrackContentFingerprint: Equatable {
    let value: UInt64

    static func make(from tracks: [Track]) -> Self {
        var value: UInt64 = 14_695_981_039_346_656_037

        for track in tracks {
            combine(track.id, into: &value)
            combine(track.genre?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", into: &value)
            combine(track.year.map(String.init) ?? "", into: &value)
            combine(
                track.dateAdded.map { String(Int64($0.timeIntervalSinceReferenceDate * 1_000_000)) } ?? "",
                into: &value
            )
            combine(track.trackStatus ?? "", into: &value)
            combine(track.canEdit ? "1" : "0", into: &value)
        }

        return Self(value: value)
    }

    private static func combine(_ string: String, into value: inout UInt64) {
        for byte in string.utf8 {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }

        value ^= 0xFF
        value &*= 1_099_511_628_211
    }
}

// MARK: - Preview

#Preview("Dashboard -- Populated") {
    DashboardView(
        tracks: PreviewData.sampleTracks,
        metricsSnapshot: nil,
        isLoadingTracks: false,
        loadError: nil,
        lastScanDate: .now,
        isDryRun: true,
        workflowState: .empty,
        onScanNow: {},
        onReviewChanges: {}
    )
    .frame(width: 700, height: 800)
}

#Preview("Dashboard -- Shimmer") {
    DashboardView(
        tracks: [],
        metricsSnapshot: nil,
        isLoadingTracks: true,
        loadError: nil,
        lastScanDate: nil,
        isDryRun: true,
        workflowState: .empty,
        onScanNow: {},
        onReviewChanges: {}
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
