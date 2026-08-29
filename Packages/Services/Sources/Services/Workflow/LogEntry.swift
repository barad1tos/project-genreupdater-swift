import Core
import Foundation

extension UpdateCoordinator {
    static func changeToLogEntry(
        _ change: ProposedChange,
        databaseID: MusicDatabaseTrackID,
        recoveryOrigin: String? = nil
    ) -> ChangeLogEntry {
        var entry = ChangeLogEntry(
            id: change.id,
            timestamp: .now,
            changeType: change.changeType,
            trackID: databaseID.rawValue,
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
            entry.albumArtistChange = change.albumArtistChange
        }

        if let recoveryOrigin {
            switch change.changeType {
            case .yearUpdate, .yearRevert:
                entry.oldYear = Int(recoveryOrigin)
            case .albumCleaning:
                entry.oldAlbumName = recoveryOrigin
            case .artistRename:
                entry.oldArtist = recoveryOrigin
            case .genreUpdate, .trackCleaning:
                break
            }
        }

        return entry
    }

    static func noOpLogEntry(
        _ change: ProposedChange,
        databaseID: MusicDatabaseTrackID
    ) -> ChangeLogEntry {
        var entry = ChangeLogEntry(
            id: change.id,
            timestamp: .now,
            changeType: change.changeType,
            trackID: databaseID.rawValue,
            artist: change.track.artist,
            trackName: change.track.name,
            albumName: change.track.album
        )

        switch change.changeType {
        case .genreUpdate:
            let value = change.newValue ?? change.oldValue ?? change.track.genre
            entry.oldGenre = value
            entry.newGenre = value
        case .yearUpdate, .yearRevert:
            let value = (change.newValue ?? change.oldValue).flatMap(Int.init) ?? change.track.year
            entry.oldYear = value
            entry.newYear = value
        case .trackCleaning:
            let value = change.newValue ?? change.oldValue ?? change.track.name
            entry.oldTrackName = value
            entry.newTrackName = value
        case .albumCleaning:
            let value = change.newValue ?? change.oldValue ?? change.track.album
            entry.oldAlbumName = value
            entry.newAlbumName = value
        case .artistRename:
            let value = change.newValue ?? change.oldValue ?? change.track.artist
            entry.oldArtist = value
            entry.newArtist = value
            entry.albumArtistChange = change.albumArtistChange
        }

        return entry
    }
}

extension ChangeLogEntry {
    func scoped(to runID: UUID) -> Self {
        var scoped = ChangeLogEntry(
            id: RunChangeID.make(runID: runID, itemID: id),
            timestamp: timestamp,
            changeType: changeType,
            trackID: trackID,
            artist: artist,
            trackName: trackName,
            albumName: albumName,
            oldGenre: oldGenre,
            newGenre: newGenre,
            oldYear: oldYear,
            newYear: newYear,
            oldTrackName: oldTrackName,
            newTrackName: newTrackName,
            oldAlbumName: oldAlbumName,
            newAlbumName: newAlbumName,
            oldArtist: oldArtist,
            newArtist: newArtist,
            albumArtistChange: albumArtistChange
        )
        scoped.runID = runID
        return scoped
    }
}
