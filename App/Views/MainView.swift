// MainView.swift — Primary library browser interface
// Ported from: src/app/cli.py (291 LOC) → SwiftUI declarative UI
//
// Python's CLI used argparse subcommands (update, update_years, clean_artist, etc.).
// SwiftUI replaces this with a NavigationSplitView layout:
// - Sidebar: command categories (Genre, Year, Batch, Reports)
// - Content: track list with search/filter
// - Detail: track inspector
//
// MusicKit provides the track data via MusicLibraryReader.

import Combine
import Core
import Services
import SharedUI
import SwiftUI

// MARK: - Sidebar Navigation

enum NavigationCategory: String, CaseIterable, Identifiable {
    case library = "Library"
    case genreUpdate = "Genre Update"
    case yearUpdate = "Year Update"
    case batchOperations = "Batch"
    case reports = "Reports"

    var id: String {
        rawValue
    }

    var icon: String {
        switch self {
        case .library: "music.note.list"
        case .genreUpdate: "tag.fill"
        case .yearUpdate: "calendar"
        case .batchOperations: "square.stack.3d.up.fill"
        case .reports: "chart.bar.fill"
        }
    }
}

// MARK: - Main View

struct MainView: View {
    @Environment(AppDependencies.self) private var dependencies
    @State private var selectedCategory: NavigationCategory? = .library
    @State private var tracks: [Track] = []
    @State private var filteredTracks: [Track] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var selectedTrack: Track?
    @State private var showUpdateSheet = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            switch selectedCategory {
            case .library, .genreUpdate, .yearUpdate, .none:
                trackList
            case .batchOperations:
                BatchView(tracks: filteredTracks)
            case .reports:
                ReportsView()
            }
        } detail: {
            trackDetail
        }
        .searchable(text: $searchText, prompt: "Search tracks...")
        .onChange(of: searchText) { updateFilteredTracks() }
        .onChange(of: tracks) { updateFilteredTracks() }
        .task {
            await loadTracks()
        }
        .onReceive(NotificationCenter.default.publisher(for: .updateSelectedTracks)) { _ in
            if !filteredTracks.isEmpty {
                showUpdateSheet = true
            }
        }
        .sheet(isPresented: $showUpdateSheet) {
            if let coordinator = dependencies.updateCoordinator,
               let pipeline = dependencies.changePreviewPipeline {
                let viewModel = UpdateViewModel(
                    updateCoordinator: coordinator,
                    changePreviewPipeline: pipeline
                )
                UpdateView(viewModel: viewModel, tracks: tracksForUpdate)
            }
        }
    }

    // MARK: - Computed Properties

    /// Tracks to send to the update sheet (falls back to all filtered tracks).
    private var tracksForUpdate: [Track] {
        filteredTracks
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(NavigationCategory.allCases, selection: $selectedCategory) { category in
            Label(category.rawValue, systemImage: category.icon)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 250)
    }

    // MARK: - Track List

    private var trackList: some View {
        Group {
            if isLoading {
                ProgressView("Loading library...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredTracks.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No Tracks" : "No Results",
                    systemImage: searchText.isEmpty ? "music.note" : "magnifyingglass",
                    description: Text(
                        searchText.isEmpty
                            ? "Your library appears empty. Make sure Music.app has tracks."
                            : "No tracks match '\(searchText)'"
                    )
                )
            } else {
                List(filteredTracks, selection: $selectedTrack) { track in
                    TrackRow(track: track)
                        .tag(track)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .navigationSplitViewColumnWidth(min: 300, ideal: 450)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Text("\(filteredTracks.count) tracks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(filteredTracks.count) tracks in library")
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await loadTracks() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh library")
                .help("Refresh library")
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    showUpdateSheet = true
                } label: {
                    Label("Update Tracks", systemImage: "wand.and.stars")
                }
                .help("Update genre and year for selected tracks")
                .disabled(filteredTracks.isEmpty)
            }
        }
    }

    // MARK: - Track Detail

    private var trackDetail: some View {
        Group {
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
    }

    // MARK: - Data

    private func updateFilteredTracks() {
        guard !searchText.isEmpty else {
            filteredTracks = tracks
            return
        }
        filteredTracks = tracks.filter { track in
            track.name.localizedStandardContains(searchText)
                || track.artist.localizedStandardContains(searchText)
                || track.album.localizedStandardContains(searchText)
                || (track.genre?.localizedStandardContains(searchText) ?? false)
        }
    }

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
