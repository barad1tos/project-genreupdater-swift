// BrowseView.swift -- Inline-expand artist/album browser with sticky sections, search, and card lift.
//
// Hierarchy:
// 1. Artist list grouped by first letter with sticky section headers
// 2. Expanded albums as indented sub-rows (inline, multiple artists open)
// 3. Album detail in NavigationSplitView third column (via selectedAlbum)
// 4. Card lift overlay: double-click lifts artist/album detail card from row position

import AppKit
import Core
import SharedUI
import SwiftUI

// MARK: - Browse View

/// Inline-expand artist/album browser for the NavigationSplitView content column.
///
/// Clicking an artist row expands its albums as indented sub-rows. Multiple artists
/// can be open simultaneously. Clicking an album sets `selectedAlbum` on the ViewModel
/// which drives the detail column. Double-clicking lifts a card overlay with rich detail.
/// Search shows grouped results across all entity types.
struct BrowseView: View {
    @Bindable var viewModel: BrowseViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isSectionBarVisible = false
    @State private var rowFrames: [String: CGRect] = [:]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                mainContent
                    .opacity(viewModel.cardLiftState != nil ? 0.4 : 1.0)
                    .animation(
                        reduceMotion ? nil : Motion.cardLiftSpring,
                        value: viewModel.cardLiftState != nil
                    )

                if let liftState = viewModel.cardLiftState {
                    CardLiftOverlay(
                        state: liftState,
                        containerSize: geometry.size,
                        onDismiss: { viewModel.dismissCardLift() },
                        content: { cardContent(for: liftState) }
                    )
                }
            }
        }
        .task(id: viewModel.searchText) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await viewModel.updateSearchResults()
        }
        .onAppear { viewModel.reduceMotion = reduceMotion }
        .onChange(of: reduceMotion) { _, newValue in
            viewModel.reduceMotion = newValue
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(spacing: 0) {
            BrowseToolbar(viewModel: viewModel)

            if viewModel.tracks.isEmpty {
                emptyLibraryState
            } else if viewModel.searchText.isEmpty {
                browseContent
            } else {
                searchResultsContent
            }
        }
    }

    // MARK: - Browse Content

    private var browseContent: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                artistList(proxy: proxy)

                SectionIndexBar(
                    letters: viewModel.sections.map(\.letter),
                    onLetterSelected: { letter in
                        withAnimation {
                            proxy.scrollTo(letter, anchor: .top)
                        }
                    }
                )
                .opacity(isSectionBarVisible ? 1 : 0)
                .animation(Motion.curveFast, value: isSectionBarVisible)
            }
            .onHover { hovering in
                isSectionBarVisible = hovering
            }
        }
    }

    // MARK: - Artist List

    private func artistList(proxy _: ScrollViewProxy) -> some View {
        Group {
            if viewModel.sections.isEmpty {
                filterEmptyState
            } else {
                List {
                    ForEach(viewModel.sections) { section in
                        Section {
                            ForEach(section.artists) { artist in
                                artistRow(artist)
                            }
                        } header: {
                            Text(section.letter)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Ayu.fgMuted)
                                .padding(.leading, Spacing.xs)
                                .id(section.letter)
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }

    // MARK: - Artist Row with Expand/Collapse

    @ViewBuilder
    private func artistRow(_ artist: ArtistGroup) -> some View {
        artistRowContent(artist)

        // Expanded album sub-rows (instant, no animation per CONTEXT.md)
        if viewModel.expandedArtists.contains(artist.canonicalName) {
            if artist.variants.count > 1 {
                ForEach(artist.variants, id: \.self) { variant in
                    Text(variant)
                        .font(AppFont.caption)
                        .foregroundStyle(Ayu.fgSecondary)
                        .padding(.leading, Spacing.xl)
                        .padding(.vertical, 2)
                }
            }

            let albums = viewModel.albumsForArtist(artist.canonicalName)
            ForEach(albums) { album in
                albumSubRow(
                    album,
                    artistName: artist.canonicalName,
                    allAlbumIDs: albums.map(\.id)
                )
            }
        }
    }

    private func artistRowContent(_ artist: ArtistGroup) -> some View {
        ArtistListRow(
            name: artist.canonicalName,
            albumCount: artist.albumCount,
            trackCount: artist.totalTrackCount,
            isSelected: viewModel.selectedItems.contains(artist.id)
        )
        .background {
            GeometryReader { geometry in
                Color.clear
                    .preference(
                        key: RowFrameKey.self,
                        value: [artist.id: geometry.frame(in: .global)]
                    )
            }
        }
        .onPreferenceChange(RowFrameKey.self) { frames in
            rowFrames.merge(frames) { _, new in new }
        }
        .contentShape(.rect)
        .overlay {
            DoubleClickDetector {
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                guard !flags.contains(.command),
                      !flags.contains(.shift) else { return }
                let frame = rowFrames[artist.id] ?? .zero
                viewModel.liftCard(
                    sourceID: artist.id,
                    contentType: .artist(name: artist.canonicalName),
                    sourceFrame: frame
                )
            }
        }
        .onTapGesture {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.command) || flags.contains(.shift) {
                viewModel.handleRowClick(
                    itemID: artist.id,
                    allVisibleIDs: viewModel.sections.flatMap { $0.artists.map(\.id) }
                )
            } else {
                viewModel.toggleExpanded(artist.canonicalName)
            }
        }
    }

    // MARK: - Album Sub-Row

    private func albumSubRow(
        _ album: AlbumSummary,
        artistName: String,
        allAlbumIDs: [String]
    ) -> some View {
        let albumID = AlbumIdentifier(
            albumName: album.name,
            artistName: artistName
        )

        return AlbumListRow(
            title: album.name,
            genre: album.primaryGenre,
            year: album.year,
            isSelected: viewModel.selectedAlbum == albumID
        )
        .padding(.leading, Spacing.lg)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .preference(
                        key: RowFrameKey.self,
                        value: [album.id: geometry.frame(in: .global)]
                    )
            }
        }
        .onPreferenceChange(RowFrameKey.self) { frames in
            rowFrames.merge(frames) { _, new in new }
        }
        .contentShape(.rect)
        .overlay {
            DoubleClickDetector {
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                guard !flags.contains(.command),
                      !flags.contains(.shift) else { return }
                let frame = rowFrames[album.id] ?? .zero
                viewModel.liftCard(
                    sourceID: album.id,
                    contentType: .album(
                        name: album.name,
                        artistName: artistName
                    ),
                    sourceFrame: frame
                )
            }
        }
        .onTapGesture {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.command) || flags.contains(.shift) {
                viewModel.handleRowClick(
                    itemID: album.id,
                    allVisibleIDs: allAlbumIDs
                )
            } else {
                viewModel.selectedAlbum = albumID
            }
        }
    }

    // MARK: - Card Content

    @ViewBuilder
    private func cardContent(for state: CardLiftState) -> some View {
        switch state.contentType {
        case let .artist(name):
            if let artist = viewModel.artistGroupForCardLift(name) {
                ArtistCardContent(
                    artist: artist,
                    albums: viewModel.albumsForArtist(name),
                    tracks: viewModel.tracksForArtist(name),
                    onAlbumDoubleTap: { album in
                        viewModel.cascadeToAlbum(
                            album: album,
                            sourceFrame: .zero
                        )
                    }
                )
            }
        case let .album(name, artistName):
            let albumID = AlbumIdentifier(
                albumName: name,
                artistName: artistName
            )
            AlbumCardContent(
                album: viewModel.albumSummary(for: albumID)
                    ?? AlbumSummary(
                        name: name,
                        artist: artistName,
                        year: nil,
                        trackCount: 0,
                        primaryGenre: nil,
                        healthRatio: 0
                    ),
                tracks: viewModel.tracksForAlbum(albumID)
            )
        }
    }
}

// MARK: - Search and Empty States

extension BrowseView {
    @ViewBuilder
    var searchResultsContent: some View {
        if let results = viewModel.searchResults, !results.isEmpty {
            List {
                if !results.artists.isEmpty {
                    Section("Artists") {
                        ForEach(results.artists) { artist in
                            ArtistListRow(
                                name: artist.canonicalName,
                                albumCount: artist.albumCount,
                                trackCount: artist.totalTrackCount
                            )
                            .contentShape(.rect)
                            .onTapGesture {
                                handleSearchArtistTap(artist)
                            }
                        }
                    }
                }
                if !results.albums.isEmpty {
                    Section("Albums") {
                        ForEach(results.albums) { album in
                            AlbumListRow(
                                title: album.name,
                                genre: album.primaryGenre,
                                year: album.year
                            )
                            .contentShape(.rect)
                            .onTapGesture {
                                handleSearchAlbumTap(album)
                            }
                        }
                    }
                }
                if !results.tracks.isEmpty {
                    Section("Tracks (\(results.tracks.count))") {
                        ForEach(results.tracks) { track in
                            TrackRow(track: track)
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        } else if viewModel.searchResults != nil {
            EmptyStateView(
                icon: "magnifyingglass",
                title: "No Results",
                description: "No matches for '\(viewModel.searchText)'",
                actionTitle: "Clear Search"
            ) {
                viewModel.searchText = ""
            }
        }
    }

    var emptyLibraryState: some View {
        EmptyStateView(
            icon: "music.note.list",
            title: "No Artists",
            description: "Your library appears empty. Grant Music access in System Settings."
        )
    }

    var filterEmptyState: some View {
        EmptyStateView(
            icon: "line.3.horizontal.decrease.circle",
            title: "No Matches",
            description: "No artists match the active filters.",
            actionTitle: "Clear Filters"
        ) {
            viewModel.activeFilters.removeAll()
            viewModel.applyFilters()
        }
    }

    func handleSearchArtistTap(_ artist: ArtistGroup) {
        viewModel.searchText = ""
        viewModel.expandedArtists.insert(artist.canonicalName)
    }

    func handleSearchAlbumTap(_ album: AlbumSummary) {
        viewModel.searchText = ""
        viewModel.expandedArtists.insert(album.artist)
        viewModel.selectedAlbum = AlbumIdentifier(
            albumName: album.name,
            artistName: album.artist
        )
    }
}

// MARK: - Row Frame Preference Key

private struct RowFrameKey: PreferenceKey {
    // Safety: only written/read on main thread via SwiftUI preference system.
    nonisolated(unsafe) static var defaultValue: [String: CGRect] = [:]

    static func reduce(
        value: inout [String: CGRect],
        nextValue: () -> [String: CGRect]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Preview

#Preview("Browse View") {
    BrowseView(viewModel: {
        let viewModel = BrowseViewModel()
        viewModel.tracks = BrowsePreviewData.sampleTracks
        return viewModel
    }())
        .frame(width: 600, height: 700)
}

#Preview("Browse View -- Empty") {
    BrowseView(viewModel: BrowseViewModel())
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
