// MainView.swift — Main interface with 4-item sidebar (Settings via Cmd+,).

import Combine
import Core
import Services
import SharedUI
import SwiftUI

// MARK: - Sidebar Navigation

enum NavigationCategory: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case browse = "Browse"
    case update = "Update"
    case reports = "Reports"

    var id: String {
        rawValue
    }

    var icon: String {
        switch self {
        case .dashboard: "gauge.open.with.lines.needle.33percent.and.arrowtriangle"
        case .browse: "music.note.list"
        case .update: "wand.and.stars"
        case .reports: "chart.bar.fill"
        }
    }

    static var allInOrder: [Self] {
        [.dashboard, .browse, .update, .reports]
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
        List(selection: $selectedCategory) {
            ForEach(NavigationCategory.allInOrder) { category in
                Label(category.rawValue, systemImage: category.icon)
                    .tag(category)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
    }

    // MARK: - Content Router

    @ViewBuilder
    private var contentView: some View {
        switch selectedCategory {
        case .dashboard, .none:
            DashboardView(tracks: tracks) { category in
                selectedCategory = category
            }

        case .browse:
            BrowseView(tracks: tracks, selectedTrack: $selectedTrack)

        case .update:
            updateContent

        case .reports:
            ReportsView()
        }
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
        if let track = selectedTrack {
            TrackDetailView(track: track)
        } else {
            ContentUnavailableView(
                "Select a Track",
                systemImage: "music.note",
                description: Text("Choose a track from the list to view details.")
            )
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
