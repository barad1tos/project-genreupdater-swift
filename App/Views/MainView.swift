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
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.modelContext) private var modelContext
    @State private var selectedCategory: NavigationCategory? = .dashboard
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    @State private var tracks: [Track] = []
    @State private var isLoading = false
    @State private var selectedTrack: Track?
    @State private var showUpdateSheet = false
    @State private var metricsSnapshot: PersistedMetricsSnapshot?
    @AppStorage("sidebarCompact") private var isSidebarCompact = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } content: {
            contentView
                .navigationTitle(selectedCategory?.rawValue ?? "Dashboard")
                .contentTransition(.opacity)
                .animation(Motion.curveFast, value: selectedCategory)
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
                DashboardView(
                    tracks: tracks,
                    metricsSnapshot: metricsSnapshot,
                    isLoadingTracks: isLoading
                ) { category in
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
            withAnimation(Motion.curveLayout) {
                columnVisibility = target
            }
        }
    }

    // MARK: - Data

    private func loadTracks() async {
        loadCachedSnapshot()

        guard let reader = dependencies.musicReader else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            try await reader.requestAuthorization()
            tracks = try await reader.fetchAllTracks()
            saveMetricsSnapshot(from: tracks)
        } catch {
            tracks = []
        }
    }

    // MARK: - Metrics Snapshot

    private func loadCachedSnapshot() {
        let descriptor = FetchDescriptor<PersistedMetricsSnapshot>()
        metricsSnapshot = try? modelContext.fetch(descriptor).first
    }

    private func saveMetricsSnapshot(from loadedTracks: [Track]) {
        guard !loadedTracks.isEmpty else { return }

        let total = loadedTracks.count
        var genreCount = 0
        var yearCount = 0
        var bothCount = 0
        var recentCount = 0
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: .now)

        for track in loadedTracks {
            let hasGenre = track.genre.map { !$0.isEmpty } ?? false
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

        let descriptor = FetchDescriptor<PersistedMetricsSnapshot>()
        let existing = try? modelContext.fetch(descriptor).first

        if let snapshot = existing {
            // Shift current values to previous before updating
            snapshot.previousTotalTracks = snapshot.totalTracks
            snapshot.previousTracksNeedingGenre = snapshot.tracksNeedingGenre
            snapshot.previousTracksNeedingYear = snapshot.tracksNeedingYear
            snapshot.previousRecentlyAdded = snapshot.recentlyAdded

            snapshot.totalTracks = total
            snapshot.tracksWithGenre = genreCount
            snapshot.tracksWithYear = yearCount
            snapshot.tracksWithBoth = bothCount
            snapshot.tracksNeedingGenre = total - genreCount
            snapshot.tracksNeedingYear = total - yearCount
            snapshot.recentlyAdded = recentCount
            snapshot.timestamp = .now
        } else {
            let snapshot = PersistedMetricsSnapshot(
                totalTracks: total,
                tracksWithGenre: genreCount,
                tracksWithYear: yearCount,
                tracksWithBoth: bothCount,
                tracksNeedingGenre: total - genreCount,
                tracksNeedingYear: total - yearCount,
                recentlyAdded: recentCount
            )
            modelContext.insert(snapshot)
        }

        try? modelContext.save()
        metricsSnapshot = try? modelContext.fetch(descriptor).first
    }
}
