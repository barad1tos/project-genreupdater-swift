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
            if tracksByID[itemID] != nil {
                selectedTrackIDs.insert(itemID)
            }

            if let album = albumIdentifier(from: itemID) {
                for track in tracksForAlbum(album) {
                    selectedTrackIDs.insert(track.id)
                }
            }

            for track in tracksForArtist(itemID) {
                selectedTrackIDs.insert(track.id)
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
