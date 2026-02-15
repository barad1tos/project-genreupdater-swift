// MainView.swift — Primary library browser interface
// Ported from: src/app/cli.py (291 LOC) → SwiftUI declarative UI
//
// Python's CLI used argparse subcommands (update, update_years, clean_artist, etc.).
// SwiftUI replaces this with a NavigationSplitView layout:
// - Sidebar: command categories (Genre, Year, Batch, Analytics)
// - Content: track list with search/filter
// - Detail: track inspector
//
// MusicKit provides the track data via MusicLibraryReader.

import Core
import SwiftUI

// MARK: - Sidebar Navigation

enum NavigationCategory: String, CaseIterable, Identifiable {
    case library = "Library"
    case genreUpdate = "Genre Update"
    case yearUpdate = "Year Update"
    case batchOperations = "Batch"
    case analytics = "Analytics"

    var id: String {
        rawValue
    }

    var icon: String {
        switch self {
        case .library: "music.note.list"
        case .genreUpdate: "tag.fill"
        case .yearUpdate: "calendar"
        case .batchOperations: "square.stack.3d.up.fill"
        case .analytics: "chart.bar.fill"
        }
    }
}

// MARK: - Main View

struct MainView: View {
    @EnvironmentObject private var dependencies: AppDependencies
    @State private var selectedCategory: NavigationCategory? = .library
    @State private var tracks: [Track] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var selectedTrack: Track?

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            trackList
        } detail: {
            trackDetail
        }
        .searchable(text: $searchText, prompt: "Search tracks...")
        .task {
            await loadTracks()
        }
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
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await loadTracks() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh library")
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

    private var filteredTracks: [Track] {
        guard !searchText.isEmpty else { return tracks }
        let query = searchText.lowercased()
        return tracks.filter { track in
            track.name.lowercased().contains(query)
                || track.artist.lowercased().contains(query)
                || track.album.lowercased().contains(query)
                || (track.genre?.lowercased().contains(query) ?? false)
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

// MARK: - Track Row

struct TrackRow: View {
    let track: Track

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(track.name)
                .font(.body)
                .lineLimit(1)

            HStack(spacing: 4) {
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !track.album.isEmpty {
                    Text("—")
                        .font(.caption)
                        .foregroundStyle(.quaternary)

                    Text(track.album)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Track Detail View

struct TrackDetailView: View {
    let track: Track

    var body: some View {
        Form {
            Section("Track Info") {
                LabeledContent("Title", value: track.name)
                LabeledContent("Artist", value: track.artist)
                LabeledContent("Album", value: track.album)
            }

            Section("Metadata") {
                LabeledContent("Genre", value: track.genre ?? "Unknown")
                LabeledContent("Year", value: track.year.map(String.init) ?? "Unknown")
                LabeledContent("Track ID", value: track.id)
            }

            if let dateAdded = track.dateAdded {
                Section("Dates") {
                    LabeledContent("Date Added", value: dateAdded.formatted(date: .abbreviated, time: .shortened))
                }
            }

            if let kind = track.kind {
                Section("Status") {
                    LabeledContent("Type", value: kind.description)
                    LabeledContent("Can Edit", value: kind.canEditMetadata ? "Yes" : "No")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
