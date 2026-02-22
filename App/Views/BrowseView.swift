// BrowseView.swift — Drill-down artist/album/track browser.
//
// Navigation hierarchy:
// 1. Artist list (grouped by first letter, sorted A-Z)
// 2. Album list for selected artist (sorted by year descending)
// 3. Track list for selected album (uses SharedUI TrackRow)

import Core
import SharedUI
import SwiftUI

// MARK: - Navigation Destinations

/// Type-safe navigation destinations for the browse drill-down.
private enum BrowseDestination: Hashable {
    case artist(String)
    case album(name: String, artist: String)
}

// MARK: - Artist Summary

/// Pre-computed summary for a single artist, used in the artist list.
private struct ArtistSummary: Identifiable, Sendable {
    let name: String
    let trackCount: Int
    let primaryGenre: String?
    let healthRatio: Double

    var id: String {
        name
    }
}

// MARK: - Album Summary

/// Pre-computed summary for a single album, used in the album list.
private struct AlbumSummary: Identifiable, Sendable {
    let name: String
    let artist: String
    let year: Int?
    let trackCount: Int
    let primaryGenre: String?

    var id: String {
        "\(artist)|\(name)"
    }
}

// MARK: - Letter Section

/// A group of artists sharing the same first letter for section headers.
private struct LetterSection: Identifiable {
    let letter: String
    let artists: [ArtistSummary]

    var id: String {
        letter
    }
}

// MARK: - Browse View

/// Drill-down browser for navigating Artist -> Album -> Track.
///
/// Uses `NavigationStack` with path-based navigation for a clean
/// push/pop experience. Artist data is grouped by first letter with
/// section headers. Search filters artists by name.
struct BrowseView: View {
    let tracks: [Track]
    @Binding var selectedTrack: Track?

    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            artistListContent
                .navigationDestination(for: BrowseDestination.self) { destination in
                    switch destination {
                    case let .artist(artistName):
                        albumListView(for: artistName)
                    case let .album(albumName, artistName):
                        trackListView(album: albumName, artist: artistName)
                    }
                }
        }
        .searchable(text: $searchText, prompt: "Search artists...")
        .task(id: searchText) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            debouncedSearchText = searchText
        }
    }

    // MARK: - Artist List

    @ViewBuilder
    private var artistListContent: some View {
        let sections = filteredSections
        if sections.isEmpty {
            emptyState
        } else {
            List(sections) { section in
                Section(section.letter) {
                    ForEach(section.artists) { artist in
                        Button {
                            navigationPath.append(
                                BrowseDestination.artist(artist.name)
                            )
                        } label: {
                            ArtistRow(
                                name: artist.name,
                                trackCount: artist.trackCount,
                                primaryGenre: artist.primaryGenre,
                                healthRatio: artist.healthRatio
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .navigationTitle("Artists")
            .navigationSubtitle(artistSubtitle(for: sections))
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            debouncedSearchText.isEmpty ? "No Artists" : "No Results",
            systemImage: debouncedSearchText.isEmpty
                ? "person.2" : "magnifyingglass",
            description: Text(
                debouncedSearchText.isEmpty
                    ? "Your library appears empty."
                    : "No artists match '\(debouncedSearchText)'"
            )
        )
        .navigationTitle("Artists")
    }

    // MARK: - Album List (per Artist)

    private func albumListView(for artistName: String) -> some View {
        let albums = albumSummaries(for: artistName)
        return Group {
            if albums.isEmpty {
                ContentUnavailableView(
                    "No Albums",
                    systemImage: "square.stack",
                    description: Text("No albums found for this artist.")
                )
            } else {
                List(albums) { album in
                    Button {
                        navigationPath.append(
                            BrowseDestination.album(
                                name: album.name,
                                artist: artistName
                            )
                        )
                    } label: {
                        AlbumCard(
                            name: album.name,
                            artist: album.artist,
                            year: album.year,
                            trackCount: album.trackCount,
                            primaryGenre: album.primaryGenre
                        )
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .navigationTitle(artistName)
        .navigationSubtitle("\(albums.count) album\(albums.count == 1 ? "" : "s")")
    }

    // MARK: - Track List (per Album)

    private func trackListView(album: String, artist: String) -> some View {
        let albumTracks = tracksForAlbum(name: album, artist: artist)
        return Group {
            if albumTracks.isEmpty {
                ContentUnavailableView(
                    "No Tracks",
                    systemImage: "music.note",
                    description: Text("No tracks found for this album.")
                )
            } else {
                List(albumTracks, selection: $selectedTrack) { track in
                    TrackRow(track: track)
                        .tag(track)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .navigationTitle(album.isEmpty ? "Unknown Album" : album)
        .navigationSubtitle(
            "\(albumTracks.count) track\(albumTracks.count == 1 ? "" : "s")"
        )
    }

    // MARK: - Data Computation

    /// All artist summaries computed from the track array.
    private var allArtistSummaries: [ArtistSummary] {
        let grouped = Dictionary(grouping: tracks) { $0.effectiveArtist }
        return grouped.map { artistName, artistTracks in
            ArtistSummary(
                name: artistName,
                trackCount: artistTracks.count,
                primaryGenre: mostCommonGenre(in: artistTracks),
                healthRatio: metadataHealthRatio(for: artistTracks)
            )
        }
        .sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Artist summaries grouped into letter sections, filtered by search.
    private var filteredSections: [LetterSection] {
        let artists: [ArtistSummary]
        if debouncedSearchText.isEmpty {
            artists = allArtistSummaries
        } else {
            let query = debouncedSearchText
            artists = allArtistSummaries.filter {
                $0.name.localizedStandardContains(query)
            }
        }

        let grouped = Dictionary(grouping: artists) { artist -> String in
            sectionLetter(for: artist.name)
        }

        return grouped.keys.sorted().map { letter in
            LetterSection(letter: letter, artists: grouped[letter] ?? [])
        }
    }

    /// Album summaries for a specific artist, sorted by year descending.
    private func albumSummaries(for artistName: String) -> [AlbumSummary] {
        let artistTracks = tracks.filter {
            $0.effectiveArtist == artistName
        }
        let grouped = Dictionary(grouping: artistTracks) { $0.album }

        return grouped.map { albumName, albumTracks in
            let year = albumTracks.compactMap(\.year).first
                ?? albumTracks.compactMap(\.releaseYear).first
            return AlbumSummary(
                name: albumName,
                artist: artistName,
                year: year,
                trackCount: albumTracks.count,
                primaryGenre: mostCommonGenre(in: albumTracks)
            )
        }
        .sorted { lhs, rhs in
            // Year descending, nil years sort last
            switch (lhs.year, rhs.year) {
            case let (left?, right?): left > right
            case (nil, _?): false
            case (_?, nil): true
            case (nil, nil):
                lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                    == .orderedAscending
            }
        }
    }

    /// Tracks for a specific album+artist, sorted by original position.
    private func tracksForAlbum(name: String, artist: String) -> [Track] {
        tracks
            .filter { $0.effectiveArtist == artist && $0.album == name }
            .sorted { lhs, rhs in
                let lhsPos = lhs.originalPosition ?? Int.max
                let rhsPos = rhs.originalPosition ?? Int.max
                return lhsPos < rhsPos
            }
    }

    // MARK: - Helpers

    /// Returns the most common genre among the given tracks.
    private func mostCommonGenre(in trackList: [Track]) -> String? {
        var frequency: [String: Int] = [:]
        for track in trackList {
            if let genre = track.genre, !genre.isEmpty {
                frequency[genre, default: 0] += 1
            }
        }
        return frequency.max(by: { $0.value < $1.value })?.key
    }

    /// Fraction of tracks that have both genre and year set.
    private func metadataHealthRatio(for trackList: [Track]) -> Double {
        guard !trackList.isEmpty else { return 0 }
        let complete = trackList.filter { track in
            if let genre = track.genre, !genre.isEmpty, track.year != nil {
                return true
            }
            return false
        }
        return Double(complete.count) / Double(trackList.count)
    }

    /// Extracts the section letter for alphabetical grouping.
    private func sectionLetter(for name: String) -> String {
        guard let first = name.first else { return "#" }
        let upper = String(first).uppercased()
        return upper.first?.isLetter == true ? upper : "#"
    }

    private func artistSubtitle(for sections: [LetterSection]) -> String {
        let totalArtists = sections.reduce(0) { $0 + $1.artists.count }
        return "\(totalArtists) artist\(totalArtists == 1 ? "" : "s")"
    }
}

// MARK: - Preview

#Preview("Browse View") {
    @Previewable @State var selectedTrack: Track?

    BrowseView(
        tracks: BrowsePreviewData.sampleTracks,
        selectedTrack: $selectedTrack
    )
    .frame(width: 600, height: 700)
}

#Preview("Browse View — Empty") {
    @Previewable @State var selectedTrack: Track?

    BrowseView(
        tracks: [],
        selectedTrack: $selectedTrack
    )
    .frame(width: 600, height: 400)
}

// MARK: - Preview Data

private enum BrowsePreviewData {
    static let sampleTracks: [Track] = {
        let entries: [TrackSeed] = [
            .init("Metallica", "Master of Puppets", "Metal", 1986),
            .init("Metallica", "Master of Puppets", "Metal", 1986),
            .init("Metallica", "...And Justice for All", "Metal", 1988),
            .init("Metallica", "...And Justice for All", "Metal", 1988),
            .init("Metallica", "The Black Album", "Metal", 1991),
            .init("Radiohead", "OK Computer", "Alternative", 1997),
            .init("Radiohead", "OK Computer", "Alternative", 1997),
            .init("Radiohead", "Kid A", "Electronic", 2000),
            .init("Radiohead", "In Rainbows", nil, nil),
            .init("Miles Davis", "Kind of Blue", "Jazz", 1959),
            .init("Miles Davis", "Kind of Blue", "Jazz", 1959),
            .init("Miles Davis", "Bitches Brew", "Jazz", 1970),
            .init("Aphex Twin", "Selected Ambient Works 85-92", "Electronic", 1992),
            .init("Aphex Twin", "Selected Ambient Works 85-92", "Electronic", 1992),
            .init("Boards of Canada", "Music Has the Right to Children", nil, nil),
            .init("Boards of Canada", "Geogaddi", "Electronic", 2002),
            .init("Bach", "Goldberg Variations", "Classical", 1741),
            .init("123 Band", "Numbers Album", "Pop", 2020),
        ]
        return entries.enumerated().map { index, seed in
            Track(
                id: "browse-\(index)",
                name: "Track \(index + 1)",
                artist: seed.artist,
                album: seed.album,
                genre: seed.genre,
                year: seed.year,
                originalPosition: index
            )
        }
    }()

    private struct TrackSeed {
        let artist: String
        let album: String
        let genre: String?
        let year: Int?

        init(_ artist: String, _ album: String, _ genre: String?, _ year: Int?) {
            self.artist = artist
            self.album = album
            self.genre = genre
            self.year = year
        }
    }
}
