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
    // Browse
    case library = "Library"
    case byArtist = "By Artist"
    case byAlbum = "By Album"
    // Actions
    case genreUpdate = "Genre Update"
    case yearUpdate = "Year Update"
    case batchOperations = "Batch"
    case reports = "Reports"
    case recentChanges = "Recent Changes"
    case playlists = "Playlists"

    var id: String {
        rawValue
    }

    var icon: String {
        switch self {
        case .library: "music.note.list"
        case .byArtist: "person.2"
        case .byAlbum: "square.stack"
        case .genreUpdate: "tag.fill"
        case .yearUpdate: "calendar"
        case .batchOperations: "square.stack.3d.up.fill"
        case .reports: "chart.bar.fill"
        case .recentChanges: "clock.arrow.circlepath"
        case .playlists: "music.note.list"
        }
    }

    /// All categories in sidebar order, used for Cmd+N shortcuts.
    static var allInOrder: [Self] {
        browseCategories + actionCategories
    }

    static var browseCategories: [Self] {
        [.library, .byArtist, .byAlbum]
    }

    static var actionCategories: [Self] {
        [
            .genreUpdate,
            .yearUpdate,
            .batchOperations,
            .reports,
            .recentChanges,
            .playlists
        ]
    }
}

// MARK: - Focused Value (Keyboard Shortcut Wiring)

/// Exposes the sidebar selection to the menu bar commands.
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
            Group {
                switch selectedCategory {
                case .library, .none:
                    trackList
                case .genreUpdate:
                    VStack(spacing: 0) {
                        actionBanner(
                            title: "Genre Update",
                            description: "Select tracks to update genre metadata",
                            icon: "tag.fill",
                            color: .orange
                        )
                        trackList
                    }
                case .yearUpdate:
                    VStack(spacing: 0) {
                        actionBanner(
                            title: "Year Update",
                            description: "Select tracks to update release year",
                            icon: "calendar",
                            color: .blue
                        )
                        trackList
                    }
                case .byArtist:
                    artistGroupedList
                case .byAlbum:
                    albumGroupedList
                case .batchOperations:
                    BatchView(tracks: filteredTracks)
                case .reports:
                    ReportsView()
                case .recentChanges:
                    recentChangesView
                case .playlists:
                    playlistsStub
                }
            }
            .navigationTitle(contentTitle)
            .navigationSubtitle("\(filteredTracks.count.formatted()) tracks")
            .animation(.easeInOut(duration: 0.2), value: selectedCategory)
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
        .focusedValue(\.selectedCategory, $selectedCategory)
    }

    // MARK: - Computed Properties

    /// Tracks to send to the update sheet (falls back to all filtered tracks).
    private var tracksForUpdate: [Track] {
        filteredTracks
    }

    private var contentTitle: String {
        selectedCategory?.rawValue ?? "Library"
    }

    private func actionBanner(
        title: String,
        description: String,
        icon: String,
        color: Color
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.quaternary)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedCategory) {
            Section("Browse") {
                ForEach(NavigationCategory.browseCategories) { category in
                    Label(category.rawValue, systemImage: category.icon)
                        .tag(category)
                }
            }

            Section("Actions") {
                ForEach(NavigationCategory.actionCategories) { category in
                    Label(category.rawValue, systemImage: category.icon)
                        .tag(category)
                }
            }
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

    // MARK: - Grouped Views

    private var artistGroupedList: some View {
        let grouped = Dictionary(grouping: filteredTracks) { $0.effectiveArtist }
        let sortedKeys = grouped.keys.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })

        return List(selection: $selectedTrack) {
            ForEach(sortedKeys, id: \.self) { artist in
                DisclosureGroup(artist) {
                    ForEach(grouped[artist] ?? []) { track in
                        TrackRow(track: track)
                            .tag(track)
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .navigationSplitViewColumnWidth(min: 300, ideal: 450)
    }

    private var albumGroupedList: some View {
        let grouped = Dictionary(grouping: filteredTracks) { $0.album }
        let sortedKeys = grouped.keys.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })

        return List(selection: $selectedTrack) {
            ForEach(sortedKeys, id: \.self) { album in
                DisclosureGroup(album.isEmpty ? "Unknown Album" : album) {
                    ForEach(grouped[album] ?? []) { track in
                        TrackRow(track: track)
                            .tag(track)
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .navigationSplitViewColumnWidth(min: 300, ideal: 450)
    }

    private var recentChangesView: some View {
        ContentUnavailableView(
            "Recent Changes",
            systemImage: "clock.arrow.circlepath",
            description: Text(
                "Changes will appear here after you update tracks. "
                    + "Check the Reports tab for the full change log."
            )
        )
    }

    private var playlistsStub: some View {
        ContentUnavailableView(
            "Playlists",
            systemImage: "music.note.list",
            description: Text(
                "Playlist support is not yet available. "
                    + "MusicKit does not provide write access to playlists in library context."
            )
        )
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
