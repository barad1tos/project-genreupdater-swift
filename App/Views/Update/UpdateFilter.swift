enum UpdateRunAlbumFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case changed = "Changed"
    case failed = "Failed"

    var id: String {
        rawValue
    }

    func matches(_ album: UpdateRunAlbumResult) -> Bool {
        switch self {
        case .all:
            true
        case .changed:
            album.changedTrackCount > 0
        case .failed:
            album.failureCount > 0
        }
    }

    func visibleAlbums(in albums: [UpdateRunAlbumResult]) -> [UpdateRunAlbumResult] {
        albums.filter(matches)
    }

    func selectedAlbum(
        in albums: [UpdateRunAlbumResult],
        selectedAlbumID: String?
    ) -> UpdateRunAlbumResult? {
        let visibleAlbums = visibleAlbums(in: albums)
        if let selectedAlbumID, let album = visibleAlbums.first(where: { $0.id == selectedAlbumID }) {
            return album
        }
        return visibleAlbums.first
    }
}
