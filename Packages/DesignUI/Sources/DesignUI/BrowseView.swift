import SwiftUI

struct BrowseView: View {
    @Bindable var model: AppModel
    @State private var query = ""
    @State private var selection: Album.ID?

    private func matches(_ a: Album) -> Bool {
        switch model.browseFilter {
        case .all: return true
        case .missingGenre: return a.genre == nil
        case .missingYear: return a.year == nil
        case .conflicts: return a.health < 0.6
        }
    }

    private var artists: [Artist] {
        model.data.artists.compactMap { artist in
            let albums = artist.albums.filter { matches($0) && (query.isEmpty || artist.name.localizedCaseInsensitiveContains(query)) }
            return albums.isEmpty ? nil : Artist(name: artist.name, genre: artist.genre, albums: albums)
        }
    }

    private var grouped: [(String, [Artist])] {
        Dictionary(grouping: artists, by: \.indexLetter).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    private var selectedAlbum: (Album, String)? {
        for a in model.data.artists {
            if let al = a.albums.first(where: { $0.id == selection }) { return (al, a.name) }
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
        HSplitView {
            // artist / album list
            List(selection: $selection) {
                ForEach(grouped, id: \.0) { letter, group in
                    Section(letter) {
                        ForEach(group) { artist in
                            DisclosureGroup {
                                ForEach(artist.albums) { al in
                                    albumRow(al).tag(al.id)
                                }
                            } label: {
                                HStack {
                                    Text(artist.name).font(.system(size: 13.5, weight: .semibold))
                                    Spacer()
                                    Text("\(artist.albums.count) alb · \(artist.totalTracks) trk")
                                        .font(.system(size: 11.5)).foregroundStyle(Ayu.fg2)
                                }
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 300, idealWidth: 360)
            .searchable(text: $query, placement: .toolbar, prompt: "Search artists")

            // detail
            Group {
                if let (album, artist) = selectedAlbum {
                    AlbumDetail(album: album, artist: artist) { model.navigate(to: .update) }
                } else {
                    ContentUnavailableView("Select an album", systemImage: "music.note")
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            .background(Ayu.window)
        }
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

    private func albumRow(_ al: Album) -> some View {
        HStack(spacing: 9) {
            Circle().fill(healthTone(al.health).color).frame(width: 7, height: 7)
            Text(al.name).font(.system(size: 13)).lineLimit(1)
            Spacer()
            if al.genre == nil { TagPill(text: "no genre", tone: .warning) }
            if let y = al.year {
                Text(String(y)).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Ayu.fg2)
            } else {
                TagPill(text: "no year", tone: .info)
            }
        }
    }
}

struct AlbumDetail: View {
    let album: Album
    let artist: String
    var onUpdate: () -> Void

    private var missing: Int { (album.genre == nil ? 1 : 0) + (album.year == nil ? 1 : 0) }

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
                            if let g = album.genre { TagPill(text: g, tone: .purple, dot: true) } else { TagPill(text: "No genre tag", tone: .warning, dot: true) }
                            if let y = album.year { TagPill(text: String(y), tone: .info, dot: true) } else { TagPill(text: "No year", tone: .info) }
                            TagPill(text: "\(Int((album.health*100).rounded()))% complete", tone: healthTone(album.health), dot: true)
                        }
                    }
                    Spacer()
                }

                if missing > 0 {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles").foregroundStyle(Ayu.accent)
                        Text("\(missing) metadata field\(missing > 1 ? "s" : "") can be auto-filled with high confidence.")
                            .font(.system(size: 13)).foregroundStyle(Ayu.fg)
                        Spacer()
                        PrimaryButton(title: "Update", symbol: "wand.and.stars", action: onUpdate)
                    }
                    .padding(14)
                    .background(Ayu.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ayu.accent.opacity(0.24)))
                }

                VStack(spacing: 0) {
                    ForEach(1...album.tracks, id: \.self) { n in
                        HStack(spacing: 12) {
                            Text("\(n)").font(.system(size: 12).monospacedDigit()).foregroundStyle(Ayu.fgMuted).frame(width: 22, alignment: .trailing)
                            Text("\(album.name.split(separator: " ").first ?? "") — track \(n)").font(.system(size: 13)).foregroundStyle(Ayu.fg).lineLimit(1)
                            Spacer()
                            Text(album.genre ?? "—").font(.system(size: 12)).foregroundStyle(Ayu.fg2)
                            Text(album.year.map(String.init) ?? "—").font(.system(size: 12).monospacedDigit()).foregroundStyle(Ayu.fg2).frame(width: 40, alignment: .trailing)
                        }
                        .padding(.vertical, 9)
                        if n < album.tracks { Divider().overlay(Ayu.glassBorder) }
                    }
                }
            }
            .padding(24)
        }
    }
}
