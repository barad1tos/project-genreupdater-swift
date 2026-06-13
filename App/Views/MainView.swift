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

    var sidebarItem: SidebarView.Item {
        SidebarView.Item(id: id, title: rawValue, icon: lucideIcon, section: section)
    }

    static var allInOrder: [Self] {
        [.dashboard, .browse, .reports, .update]
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

struct MainView: View {
    @Environment(AppDependencies.self) var dependencies
    @Environment(\.modelContext) var modelContext
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.motionScale) var motionScale
    @State var selectedCategory: NavigationCategory? = .dashboard
    @State var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    @State var tracks: [Track] = []
    @State var isLoading = false
    @State var browseViewModel = BrowseViewModel()
    @State var showUpdateSheet = false
    @State var metricsSnapshot: PersistedMetricsSnapshot?
    @State var libraryLoadError: LibraryLoadError?
    @State var lastLibraryScanDate: Date?
    @State var workflowViewModel: WorkflowViewModel?
    @State var hasNavigated = false
    @AppStorage("sidebarCompact") var isSidebarCompact = false
    @AppStorage("defaultUpdateBehavior") var defaultUpdateBehavior = UpdateBehavior.both.rawValue

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } content: {
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
        } detail: {
            trackDetail
        }
        .toolbar(removing: .sidebarToggle)
        .navigationSplitViewStyle(.balanced)
        .task { await loadTracks() }
        .onReceive(NotificationCenter.default.publisher(for: .updateSelectedTracks)) { _ in
            selectedCategory = .update
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToUpdate)) { _ in
            selectedCategory = .update
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
        .sheet(isPresented: $showUpdateSheet) {
            updateSheet
        }
        .focusedValue(\.selectedCategory, $selectedCategory)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        SidebarView(
            selectedItemID: Binding(
                get: { selectedCategory?.id },
                set: { newID in
                    selectedCategory = NavigationCategory.allInOrder.first { $0.id == newID }
                }
            ),
            items: NavigationCategory.allInOrder.map(\.sidebarItem),
            onSettingsTapped: {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        )
        .navigationSplitViewColumnWidth(
            min: isSidebarCompact ? 52 : 160,
            ideal: isSidebarCompact ? 52 : 200,
            max: isSidebarCompact ? 52 : 260
        )
    }

    // MARK: - Content Router

    @ViewBuilder
    private var contentView: some View {
        switch selectedCategory {
        case .dashboard, .none:
            centeredContent {
                DashboardView(
                    tracks: tracks,
                    metricsSnapshot: metricsSnapshot,
                    isLoadingTracks: isLoading,
                    loadError: libraryLoadError,
                    lastScanDate: lastLibraryScanDate,
                    isDryRun: dependencies.config.runtime.dryRun,
                    workflowState: workflowViewModel?.dashboardState ?? .empty,
                    onScanNow: {
                        Task { await loadTracks(forceRefresh: true) }
                    },
                    onReviewChanges: {
                        selectedCategory = .update
                    },
                    onNavigate: { category in
                        selectedCategory = category
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
        @ViewBuilder content: () -> some View
    ) -> some View {
        content()
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Update Content

    @ViewBuilder
    private var updateContent: some View {
        if let viewModel = workflowViewModel {
            UpdateWorkflowView(viewModel: viewModel, tracks: tracks)
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
        if selectedCategory == .browse {
            BrowseDetailView(viewModel: browseViewModel)
        } else {
            Color.clear
        }
    }

    // MARK: - Update Sheet (legacy Cmd+U support)

    @ViewBuilder
    private var updateSheet: some View {
        if let coordinator = dependencies.updateCoordinator,
           let pipeline = dependencies.changePreviewPipeline {
            let viewModel = UpdateViewModel(
                updateCoordinator: coordinator,
                changePreviewPipeline: pipeline,
                featureGate: dependencies.featureGate,
                recordProcessedTracks: { count in
                    dependencies.subscriptionService?.incrementFreeTracksUsed(by: count)
                },
                defaultUpdateGenre: configuredUpdateSelection.updateGenre,
                defaultUpdateYear: configuredUpdateSelection.updateYear,
                defaultPreviewOnly: configuredPreviewOnly,
                defaultMinConfidence: configuredMinConfidence
            )
            UpdateView(viewModel: viewModel, tracks: tracks)
        }
    }
}
