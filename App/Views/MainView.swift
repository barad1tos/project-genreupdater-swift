// MainView.swift — Main interface with custom sidebar (Settings via Cmd+,).

import Combine
import Core
import LucideIcons
import Services
import SharedUI
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
    @Environment(AppDependencies.self) private var dependencies
    @State private var selectedCategory: NavigationCategory? = .dashboard
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    @State private var tracks: [Track] = []
    @State private var isLoading = false
    @State private var selectedTrack: Track?
    @State private var showUpdateSheet = false
    @AppStorage("sidebarCompact") private var isSidebarCompact = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } content: {
            contentView
                .navigationTitle(selectedCategory?.rawValue ?? "Dashboard")
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: selectedCategory)
        } detail: {
            trackDetail
        }
        .toolbar(removing: .sidebarToggle)
        .navigationSplitViewStyle(.balanced)
        .task { await loadTracks() }
        .onReceive(NotificationCenter.default.publisher(for: .updateSelectedTracks)) { _ in
            selectedCategory = .update
        }
        .onChange(of: selectedCategory) { updateColumnVisibility() }
        .onChange(of: selectedTrack) { updateColumnVisibility() }
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
                DashboardView(tracks: tracks) { category in
                    selectedCategory = category
                }
            }

        case .browse:
            BrowseView(tracks: tracks, selectedTrack: $selectedTrack)

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

    private var updateContent: some View {
        VStack(spacing: 0) {
            if let coordinator = dependencies.updateCoordinator,
               let pipeline = dependencies.changePreviewPipeline,
               let processor = dependencies.batchProcessor {
                let viewModel = WorkflowViewModel(
                    updateCoordinator: coordinator,
                    batchProcessor: processor,
                    changePreviewPipeline: pipeline
                )
                UpdateWorkflowView(viewModel: viewModel, tracks: tracks)
            } else {
                ContentUnavailableView(
                    "Services Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Update services are still initializing. Please wait.")
                )
            }
        }
    }

    // MARK: - Track Detail

    @ViewBuilder
    private var trackDetail: some View {
        if selectedCategory == .browse, let track = selectedTrack {
            TrackDetailView(track: track)
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
                changePreviewPipeline: pipeline
            )
            UpdateView(viewModel: viewModel, tracks: tracks)
        }
    }

    // MARK: - Column Visibility

    private func updateColumnVisibility() {
        let needsDetail = selectedCategory == .browse && selectedTrack != nil
        let target: NavigationSplitViewVisibility = needsDetail ? .all : .doubleColumn
        if columnVisibility != target {
            withAnimation(.easeInOut(duration: 0.25)) {
                columnVisibility = target
            }
        }
    }

    // MARK: - Data

    private func loadTracks() async {
        guard let reader = dependencies.musicReader else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            try await reader.requestAuthorization()
            tracks = try await reader.fetchAllTracks()
        } catch {
            tracks = []
        }
    }
}
