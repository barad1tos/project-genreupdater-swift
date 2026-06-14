// BrowseSelection.swift -- selected browse rows as update workflow scope.

import Core

extension BrowseViewModel {
    func selectedTracksForUpdate() -> [Track] {
        guard !selectedItems.isEmpty else { return [] }

        var selectedTrackIDs: Set<String> = []
        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })

        for itemID in selectedItems {
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
        let parts = itemID.split(
            separator: "|",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard parts.count == 2 else { return nil }

        return AlbumIdentifier(
            albumName: String(parts[1]),
            artistName: String(parts[0])
        )
    }
}
