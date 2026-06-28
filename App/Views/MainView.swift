// MainView.swift — Main interface with custom sidebar (Settings via Cmd+,).

import Combine
import Core
import LucideIcons
import Services
import SharedUI
import SwiftData
import SwiftUI

// MARK: - Sidebar Navigation

enum NavigationCategory: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case browse = "Browse"
    case reports = "Reports"
    case update = "Update"

    var id: String {
        rawValue
    }

    var section: String {
        switch self {
        case .dashboard, .browse, .reports: "LIBRARY"
        case .update: "TOOLS"
        }
    }

    var lucideIcon: NSImage {
        switch self {
        case .dashboard: Lucide.layoutDashboard
        case .browse: Lucide.music2
        case .reports: Lucide.chartBar
        case .update: Lucide.wandSparkles
        }
    }

    func sidebarItem(badge: SidebarBadge? = nil) -> SidebarView.Item {
        SidebarView.Item(id: id, title: rawValue, icon: lucideIcon, section: section, badge: badge)
    }

    static var allInOrder: [Self] {
        [.dashboard, .browse, .reports, .update]
    }
}

// MARK: - Sidebar Badge Mapping

private enum SidebarBadgeFactory {
    static func badge(
        for category: NavigationCategory,
        snapshot: LibraryDashboardSnapshot,
        workflowState: WorkflowDashboardState,
        isEnabled: Bool
    ) -> SidebarBadge? {
        guard isEnabled else {
            return nil
        }

        switch category {
        case .dashboard:
            return dashboardBadge(from: snapshot)
        case .browse:
            return browseBadge(from: snapshot)
        case .reports:
            return reportsBadge(from: snapshot)
        case .update:
            return updateBadge(from: workflowState)
        }
    }

    private static func dashboardBadge(from snapshot: LibraryDashboardSnapshot) -> SidebarBadge? {
        switch snapshot.scanState {
        case .loading:
            return SidebarBadge(
                value: "...",
                tone: .info,
                accessibilityLabel: "library scan in progress"
            )
        case .permissionDenied, .failed:
            return SidebarBadge(
                value: "!",
                tone: .critical,
                accessibilityLabel: "library scan needs attention"
            )
        case .empty:
            return nil
        case .ready:
            guard snapshot.totalTracks > 0 else {
                return nil
            }
            return SidebarBadge(
                value: "\(snapshot.healthPercentage)%",
                tone: healthTone(snapshot.healthPercentage),
                accessibilityLabel: "\(snapshot.healthPercentage) percent library health"
            )
        }
    }

    private static func browseBadge(from snapshot: LibraryDashboardSnapshot) -> SidebarBadge? {
        if case .loading = snapshot.scanState, snapshot.totalTracks == 0 {
            return SidebarBadge(
                value: "...",
                tone: .info,
                accessibilityLabel: "library scan in progress"
            )
        }

        guard snapshot.totalTracks > 0 else {
            return nil
        }

        return SidebarBadge(
            value: compactCount(snapshot.totalTracks),
            accessibilityLabel: "\(snapshot.totalTracks) tracks"
        )
    }

    private static func reportsBadge(from snapshot: LibraryDashboardSnapshot) -> SidebarBadge? {
        let issueCategoryCount = snapshot.issues.count { issue in
            issue.count >= 1
        }
        guard issueCategoryCount > 0 else {
            return nil
        }

        return SidebarBadge(
            value: compactCount(issueCategoryCount),
            tone: .warning,
            accessibilityLabel: "\(issueCategoryCount) report issues"
        )
    }

    private static func updateBadge(from workflowState: WorkflowDashboardState) -> SidebarBadge? {
        if workflowState.failedWriteCount > 0 {
            return SidebarBadge(
                value: compactCount(workflowState.failedWriteCount),
                tone: .critical,
                accessibilityLabel: "\(workflowState.failedWriteCount) write errors"
            )
        }

        if workflowState.isProcessing {
            return SidebarBadge(
                value: "...",
                tone: .info,
                accessibilityLabel: "update workflow in progress"
            )
        }

        if workflowState.acceptedChangeCount > 0 {
            return SidebarBadge(
                value: compactCount(workflowState.acceptedChangeCount),
                tone: .success,
                accessibilityLabel: "\(workflowState.acceptedChangeCount) accepted changes ready"
            )
        }

        if workflowState.proposedChangeCount > 0 {
            return SidebarBadge(
                value: compactCount(workflowState.proposedChangeCount),
                accessibilityLabel: "\(workflowState.proposedChangeCount) proposed changes"
            )
        }

        return nil
    }

    private static func healthTone(_ percentage: Int) -> SidebarBadge.Tone {
        if percentage >= 90 {
            return .success
        }
        if percentage >= 70 {
            return .warning
        }
        return .critical
    }

    private static func compactCount(_ count: Int) -> String {
        if count < 1000 {
            return "\(count)"
        }
        if count < 10000 {
            let thousands = count / 1000
            let decimal = count % 1000 / 100
            return decimal == 0 ? "\(thousands)K" : "\(thousands).\(decimal)K"
        }
        if count < 1_000_000 {
            return "\(count / 1000)K"
        }
        return "\(count / 1_000_000)M"
    }
}

// MARK: - Focused Value (Keyboard Shortcut Wiring)

struct FocusedCategoryKey: FocusedValueKey {
    typealias Value = Binding<NavigationCategory?>
}

extension FocusedValues {
    var selectedCategory: Binding<NavigationCategory?>? {
        get { self[FocusedCategoryKey.self] }
        set { self[FocusedCategoryKey.self] = newValue }
    }
}

// MARK: - Main View

// Legacy SwiftUI shell retained as the parity fallback while DesignUI adopts the remaining workflows.

struct MainView: View {
    @Environment(AppDependencies.self) var dependencies
    @Environment(\.modelContext) var modelContext
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.motionScale) var motionScale
    @Environment(\.openSettings) var openSettings
    @State var selectedCategory: NavigationCategory? = .dashboard
    @State var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    @State var tracks: [Track] = []
    @State var isLoading = false
    @State var isMutationMetadataReady = false
    @State var libraryLoadTask: Task<Void, Never>?
    @State var libraryLoadRequestID = UUID()
    @State var browseViewModel = BrowseViewModel()
    @State var metricsSnapshot: PersistedMetricsSnapshot?
    @State var libraryLoadError: LibraryLoadError?
    @State var lastLibraryScanDate: Date?
    @State var workflowViewModel: WorkflowViewModel?
    @State var updateScopeTracks: [Track]?
    @State var pendingSelectedUpdateScopeConfiguration: SelectedUpdateScopeConfiguration?
    @State var workflowNoticeMessage: String?
    @State var hasNavigated = false
    @AppStorage("sidebarCompact") var isSidebarCompact = false
    @AppStorage("sidebarBadgesEnabled") var areSidebarBadgesEnabled = false
    @AppStorage("defaultUpdateBehavior") var defaultUpdateBehavior = UpdateBehavior.both.rawValue

    var body: some View {
        navigationShell
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewStyle(.balanced)
            .task { startLibraryLoad() }
            .onAppear { updateColumnVisibility() }
            .onReceive(NotificationCenter.default.publisher(for: .updateSelectedTracks)) { _ in
                prepareSelectedTracksUpdate()
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateToUpdate)) { _ in
                prepareDefaultUpdate()
            }
            .onReceive(NotificationCenter.default.publisher(for: .browseAction)) { notification in
                handleBrowseAction(notification)
            }
            .onChange(of: selectedCategory) {
                if !hasNavigated { hasNavigated = true }
                updateColumnVisibility()
            }
            .onChange(of: browseViewModel.selectedAlbum) { updateColumnVisibility() }
            .onChange(of: defaultUpdateBehavior) { applyWorkflowDefaults() }
            .onChange(of: dependencies.config.runtime.dryRun) { applyWorkflowDefaults() }
            .onChange(of: dependencies.config.yearRetrieval.logic.minConfidenceForNewYear) {
                applyWorkflowDefaults()
            }
            .onChange(of: dependencies.config.processing.releaseYearRestoreThreshold) {
                applyWorkflowDefaults()
            }
            .onChange(of: dependencies.config.development.testArtists) {
                handleTestArtistScopeChange()
            }
            .focusedValue(\.selectedCategory, selectedCategoryBinding)
    }

    private func handleTestArtistScopeChange() {
        guard workflowViewModel?.canStart ?? true else {
            workflowNoticeMessage = "Finish or reset the current update before changing the test artist scope."
            selectedCategory = .update
            return
        }

        updateScopeTracks = nil
        pendingSelectedUpdateScopeConfiguration = nil
        workflowNoticeMessage = nil
        tracks = []
        browseViewModel.tracks = []
        metricsSnapshot = nil
        lastLibraryScanDate = nil
        workflowViewModel?.reset()
        applyWorkflowDefaults()
        startLibraryLoad(forceRefresh: true)
    }

    @ViewBuilder
    private var navigationShell: some View {
        if usesBrowseDetailColumn {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar
            } content: {
                routedContent
            } detail: {
                trackDetail
            }
        } else {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar
            } detail: {
                routedContent
            }
        }
    }

    private var usesBrowseDetailColumn: Bool {
        selectedCategory == .browse && browseViewModel.selectedAlbum != nil
    }

    // MARK: - Sidebar

    private var sidebarItems: [SidebarView.Item] {
        let snapshot = sidebarDashboardSnapshot
        let workflowState = workflowDashboardState
        return NavigationCategory.allInOrder.map { category in
            category.sidebarItem(
                badge: SidebarBadgeFactory.badge(
                    for: category,
                    snapshot: snapshot,
                    workflowState: workflowState,
                    isEnabled: areSidebarBadgesEnabled
                )
            )
        }
    }

    private var workflowDashboardState: WorkflowDashboardState {
        workflowViewModel?.dashboardState ?? .empty
    }

    private var sidebarDashboardSnapshot: LibraryDashboardSnapshot {
        if tracks.isEmpty, isLoading, libraryLoadError == nil, let metricsSnapshot {
            return LibraryDashboardSnapshot.make(
                persistedMetrics: metricsSnapshot,
                isLoading: isLoading,
                loadError: libraryLoadError,
                isDryRun: dependencies.config.runtime.dryRun,
                workflow: workflowDashboardState
            )
        }

        return LibraryDashboardSnapshot.make(
            tracks: tracks,
            lastScanDate: lastLibraryScanDate,
            isLoading: isLoading,
            loadError: libraryLoadError,
            isDryRun: dependencies.config.runtime.dryRun,
            workflow: workflowDashboardState
        )
    }

    private var sidebar: some View {
        SidebarView(
            selectedItemID: Binding(
                get: { selectedCategory?.id },
                set: { newID in
                    selectCategory(NavigationCategory.allInOrder.first { $0.id == newID })
                }
            ),
            items: sidebarItems,
            onSettingsTapped: {
                openSettings()
            }
        )
        .navigationSplitViewColumnWidth(
            min: isSidebarCompact ? 52 : 160,
            ideal: isSidebarCompact ? 52 : 200,
            max: isSidebarCompact ? 52 : 260
        )
    }

    // MARK: - Content Router

    private var routedContent: some View {
        contentView
            .id(selectedCategory)
            .navigationTitle(selectedCategory?.rawValue ?? "Dashboard")
            .transition(
                .asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 6)),
                    removal: .opacity
                )
            )
            .animation(
                hasNavigated && !reduceMotion
                    ? Motion.scaled(Motion.curveSmooth, by: motionScale)
                    : .none,
                value: selectedCategory
            )
    }

    @ViewBuilder
    private var contentView: some View {
        switch selectedCategory {
        case .dashboard, .none:
            centeredContent(maxWidth: 1120) {
                DashboardView(
                    tracks: tracks,
                    metricsSnapshot: metricsSnapshot,
                    isLoadingTracks: isLoading,
                    loadError: libraryLoadError,
                    lastScanDate: lastLibraryScanDate,
                    isDryRun: dependencies.config.runtime.dryRun,
                    workflowState: workflowDashboardState,
                    credentialIssue: dependencies.discogsCredentialIssue,
                    onScanNow: {
                        startLibraryLoad(forceRefresh: true)
                    },
                    onReviewChanges: {
                        prepareDefaultUpdate()
                    }
                )
            }

        case .browse:
            BrowseView(viewModel: browseViewModel)

        case .update:
            centeredContent {
                updateContent
            }

        case .reports:
            centeredContent {
                ReportsView()
            }
        }
    }

    // MARK: - Centered Content Container

    private func centeredContent(
        maxWidth: CGFloat = 800,
        @ViewBuilder content: () -> some View
    ) -> some View {
        content()
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Update Content

    @ViewBuilder
    private var updateContent: some View {
        if let viewModel = workflowViewModel {
            UpdateWorkflowView(
                viewModel: viewModel,
                tracks: updateWorkflowTracks,
                testArtists: dependencies.config.development.testArtists,
                reportDisplayMode: dependencies.config.reporting.changeDisplayMode,
                credentialIssue: dependencies.discogsCredentialIssue,
                isLibraryReadyForUpdates: !isLoading && isMutationMetadataReady,
                noticeMessage: $workflowNoticeMessage
            )
        } else {
            ContentUnavailableView(
                "Services Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("Update services are still initializing. Please wait.")
            )
        }
    }

    // MARK: - Track Detail

    @ViewBuilder
    private var trackDetail: some View {
        if usesBrowseDetailColumn {
            BrowseDetailView(viewModel: browseViewModel)
        } else {
            Color.clear
        }
    }
}
