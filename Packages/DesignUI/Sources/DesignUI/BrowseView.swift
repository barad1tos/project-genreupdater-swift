import SwiftUI

struct BrowseView: View {
    @Bindable var model: AppModel
    var albumUpdateAction: ((Album, String) -> Void)?
    var albumSelectionAction: ((Album?, String?) -> Void)?
    @SceneStorage("DesignUI.BrowseView.availableWidth") private var storedAvailableWidth = 0.0
    @State private var query = ""
    @State private var selection: Album.ID?

    private let listWidthShare: CGFloat = 0.42

    private func matches(_ album: Album) -> Bool {
        switch model.browseFilter {
        case .all: true
        case .missingGenre: album.genre == nil
        case .missingYear: album.year == nil
        case .conflicts: album.health < 0.6
        }
    }

    private var artists: [Artist] {
        model.data.artists.compactMap { artist in
            let albums = artist.albums.filter {
                matches($0) && (query.isEmpty || artist.name.localizedCaseInsensitiveContains(query))
            }
            return albums.isEmpty ? nil : Artist(
                id: artist.id,
                name: artist.name,
                genre: artist.genre,
                albums: albums
            )
        }
    }

    private var grouped: [ArtistSection] {
        Dictionary(grouping: artists, by: \.indexLetter).sorted { $0.key < $1.key }.map {
            ArtistSection(letter: $0.key, artists: $0.value)
        }
    }

    private var selectedAlbum: (Album, String)? {
        for artist in model.data.artists {
            if let album = artist.albums.first(where: { $0.id == selection }) {
                return (album, artist.name)
            }
        }
        return nil
    }

    private var browseFilterSelection: Binding<BrowseFilter> {
        Binding {
            model.browseFilter
        } set: { filter in
            model.setBrowseFilter(filter)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            browseContent(availableWidth: resolvedAvailableWidth(geometry.size.width))
                .onAppear { storeAvailableWidth(geometry.size.width) }
                .onChange(of: geometry.size.width) { _, width in
                    storeAvailableWidth(width)
                }
                .onChange(of: selection) {
                    publishSelectedAlbum()
                }
        }
        .onAppear { publishSelectedAlbum() }
        .background(Ayu.window)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Filter", selection: browseFilterSelection) {
                    ForEach(BrowseFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .navigationTitle("Browse")
    }

    private func browseContent(availableWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            artistList(width: availableWidth * listWidthShare)

            FadingVerticalSeparator()

            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Ayu.window)
        }
    }

    private func resolvedAvailableWidth(_ width: CGFloat) -> CGFloat {
        guard width.isFinite, width > .zero else { return CGFloat(storedAvailableWidth) }
        return width
    }

    private func storeAvailableWidth(_ width: CGFloat) {
        guard width.isFinite, width > .zero else { return }
        storedAvailableWidth = Double(width)
    }

    private func publishSelectedAlbum() {
        if let (album, artist) = selectedAlbum {
            albumSelectionAction?(album, artist)
        } else {
            albumSelectionAction?(nil, nil)
        }
    }

    private func artistList(width: CGFloat) -> some View {
        List(selection: $selection) {
            ForEach(grouped) { section in
                Section(section.letter) {
                    ForEach(section.artists) { artist in
                        DisclosureGroup {
                            ForEach(artist.albums) { album in
                                albumRow(album).tag(album.id)
                            }
                        } label: {
                            artistRow(artist)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Ayu.window)
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .searchable(text: $query, placement: .toolbar, prompt: "Search artists")
    }

    private func artistRow(_ artist: Artist) -> some View {
        HStack {
            Text(artist.name)
                .font(.system(size: 13.5, weight: .semibold))
                .lineLimit(1)
            Spacer()
            Text("\(artist.albums.count) alb · \(artist.totalTracks) trk")
                .font(.system(size: 11.5))
                .foregroundStyle(Ayu.fg2)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let (album, artist) = selectedAlbum {
            AlbumDetail(album: album, artist: artist) {
                if let albumUpdateAction {
                    albumUpdateAction(album, artist)
                } else {
                    model.navigate(to: .update)
                }
            }
        } else {
            ContentUnavailableView("Select an album", systemImage: "music.note")
        }
    }

    private func albumRow(_ album: Album) -> some View {
        HStack(spacing: 9) {
            Circle().fill(healthTone(album.health).color).frame(width: 7, height: 7)
            Text(album.name).font(.system(size: 13)).lineLimit(1)
            Spacer()
            if album.genre == nil {
                TagPill(text: "no genre", tone: .warning)
            }
            if let year = album.year {
                Text(String(year)).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Ayu.fg2)
            } else {
                TagPill(text: "no year", tone: .info)
            }
        }
    }
}

private struct ArtistSection: Identifiable {
    let letter: String
    let artists: [Artist]

    var id: String {
        letter
    }
}

private struct FadingVerticalSeparator: View {
    private let fadeStart = 0.95

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: Ayu.glassBorder, location: 0),
                        .init(color: Ayu.glassBorder, location: fadeStart),
                        .init(color: Ayu.glassBorder.opacity(0), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 1)
            .accessibilityHidden(true)
    }
}

struct AlbumDetail: View {
    let album: Album
    let artist: String
    var onUpdate: () -> Void

    private var missing: Int {
        (album.genre == nil ? 1 : 0) + (album.year == nil ? 1 : 0)
    }
    private var autofillMessage: String {
        "\(missing) metadata field\(missing > 1 ? "s" : "") can be auto-filled with high confidence."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(healthTone(album.health).color.opacity(0.8))
                        .frame(width: 72, height: 72)
                        .overlay(Image(systemName: "music.note").font(.system(size: 30)).foregroundStyle(Ayu.onAccent))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(album.name).font(.system(size: 19, weight: .bold))
                        Text(artist).font(.system(size: 13.5)).foregroundStyle(Ayu.fg2)
                        HStack(spacing: 7) {
                            if let genre = album.genre {
                                TagPill(text: genre, tone: .purple, dot: true)
                            } else {
                                TagPill(text: "No genre tag", tone: .warning, dot: true)
                            }
                            if let year = album.year {
                                TagPill(text: String(year), tone: .info, dot: true)
                            } else {
                                TagPill(text: "No year", tone: .info)
                            }
                            TagPill(
                                text: "\(Int((album.health * 100).rounded()))% complete",
                                tone: healthTone(album.health),
                                dot: true
                            )
                        }
                    }
                    Spacer()
                }

                if missing > 0 {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles").foregroundStyle(Ayu.accent)
                        Text(autofillMessage)
                            .font(.system(size: 13))
                            .foregroundStyle(Ayu.fg)
                        Spacer()
                        PrimaryButton(title: "Update", symbol: "wand.and.stars", action: onUpdate)
                    }
                    .padding(14)
                    .background(Ayu.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ayu.accent.opacity(0.24)))
                }

                VStack(spacing: 0) {
                    ForEach(1 ... album.tracks, id: \.self) { trackNumber in
                        HStack(spacing: 12) {
                            Text("\(trackNumber)")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Ayu.fgMuted)
                                .frame(width: 22, alignment: .trailing)
                            Text("\(album.name.split(separator: " ").first ?? "") — track \(trackNumber)")
                                .font(.system(size: 13))
                                .foregroundStyle(Ayu.fg)
                                .lineLimit(1)
                            Spacer()
                            Text(album.genre ?? "—").font(.system(size: 12)).foregroundStyle(Ayu.fg2)
                            Text(album.year.map(String.init) ?? "—")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Ayu.fg2)
                                .frame(width: 40, alignment: .trailing)
                        }
                        .padding(.vertical, 9)
                        if trackNumber < album.tracks {
                            Divider().overlay(Ayu.glassBorder)
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}
