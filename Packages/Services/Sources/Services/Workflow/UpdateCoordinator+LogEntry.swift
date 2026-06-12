import Core

extension UpdateCoordinator {
    static func changeToLogEntry(_ change: ProposedChange) -> ChangeLogEntry {
        var entry = ChangeLogEntry(
            changeType: change.changeType,
            trackID: change.track.id,
            artist: change.track.artist,
            trackName: change.track.name,
            albumName: change.track.album
        )

        switch change.changeType {
        case .genreUpdate:
            entry.oldGenre = change.oldValue
            entry.newGenre = change.newValue
        case .yearUpdate, .yearRevert:
            entry.oldYear = change.oldValue.flatMap(Int.init)
            entry.newYear = change.newValue.flatMap(Int.init)
        case .trackCleaning:
            entry.oldTrackName = change.oldValue
            entry.newTrackName = change.newValue
        case .albumCleaning:
            entry.oldAlbumName = change.oldValue
            entry.newAlbumName = change.newValue
        case .artistRename:
            entry.oldArtist = change.oldValue
            entry.newArtist = change.newValue
        }

        return entry
    }
}
