// BrowseSelection.swift -- selected browse rows as update workflow scope.

import Core

extension BrowseViewModel {
    func selectedTracksForUpdate() -> [Track] {
        tracksForUpdate(itemIDs: selectedItems)
    }

    func tracksForUpdate(itemIDs: Set<String>) -> [Track] {
        guard !itemIDs.isEmpty else { return [] }

        var selectedTrackIDs: Set<String> = []
        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })

        for itemID in itemIDs {
            guard let selectionItem = BrowseSelectionItem(id: itemID) else { continue }

            switch selectionItem {
            case let .track(trackID):
                if tracksByID[trackID] != nil {
                    selectedTrackIDs.insert(trackID)
                }
            case let .album(albumID):
                guard let album = albumIdentifier(from: albumID) else { continue }
                for track in tracksForAlbum(album) {
                    selectedTrackIDs.insert(track.id)
                }
            case let .artist(artistID):
                for track in tracksForArtist(artistID) {
                    selectedTrackIDs.insert(track.id)
                }
            }
        }

        return tracks.filter { selectedTrackIDs.contains($0.id) }
    }

    private func albumIdentifier(from itemID: String) -> AlbumIdentifier? {
        for track in tracks where AlbumSummary.makeID(artist: track.effectiveArtist, name: track.album) == itemID {
            return AlbumIdentifier(albumName: track.album, artistName: track.effectiveArtist)
        }

        return nil
    }
}
