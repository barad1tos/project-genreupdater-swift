// PersistedChangeLogEntry.swift — SwiftData model for undo change log
// Phase 5 Audit Fix: H1 — UndoCoordinator persistence

import Core
import Foundation
import SwiftData

/// Persistent representation of a change log entry for undo support.
///
/// Stores metadata changes applied to tracks so that `UndoCoordinator`
/// can restore history across app restarts. Each entry maps 1:1 to
/// a `Core.ChangeLogEntry`.
@Model
public final class PersistedChangeLogEntry {
    @Attribute(.unique)
    public var entryID: UUID

    public var timestamp: Date
    public var changeTypeRaw: String
    public var trackID: String
    public var artist: String
    public var trackName: String
    public var albumName: String

    // Genre changes
    public var oldGenre: String?
    public var newGenre: String?

    // Year changes
    public var oldYear: Int?
    public var newYear: Int?

    // Name cleaning changes
    public var oldTrackName: String?
    public var newTrackName: String?
    public var oldAlbumName: String?
    public var newAlbumName: String?

    /// Relationship to PersistedTrack (set in H3)
    public var track: PersistedTrack?

    public init(
        entryID: UUID,
        timestamp: Date,
        changeTypeRaw: String,
        trackID: String,
        artist: String,
        trackName: String,
        albumName: String,
        oldGenre: String? = nil,
        newGenre: String? = nil,
        oldYear: Int? = nil,
        newYear: Int? = nil,
        oldTrackName: String? = nil,
        newTrackName: String? = nil,
        oldAlbumName: String? = nil,
        newAlbumName: String? = nil
    ) {
        self.entryID = entryID
        self.timestamp = timestamp
        self.changeTypeRaw = changeTypeRaw
        self.trackID = trackID
        self.artist = artist
        self.trackName = trackName
        self.albumName = albumName
        self.oldGenre = oldGenre
        self.newGenre = newGenre
        self.oldYear = oldYear
        self.newYear = newYear
        self.oldTrackName = oldTrackName
        self.newTrackName = newTrackName
        self.oldAlbumName = oldAlbumName
        self.newAlbumName = newAlbumName
    }
}

// MARK: - Conversion to/from Core.ChangeLogEntry

extension PersistedChangeLogEntry {
    public convenience init(from entry: Core.ChangeLogEntry) {
        self.init(
            entryID: entry.id,
            timestamp: entry.timestamp,
            changeTypeRaw: entry.changeType.rawValue,
            trackID: entry.trackID,
            artist: entry.artist,
            trackName: entry.trackName,
            albumName: entry.albumName,
            oldGenre: entry.oldGenre,
            newGenre: entry.newGenre,
            oldYear: entry.oldYear,
            newYear: entry.newYear,
            oldTrackName: entry.oldTrackName,
            newTrackName: entry.newTrackName,
            oldAlbumName: entry.oldAlbumName,
            newAlbumName: entry.newAlbumName
        )
    }

    public func toChangeLogEntry() -> Core.ChangeLogEntry {
        let changeType = Core.ChangeType(rawValue: changeTypeRaw) ?? .genreUpdate
        return Core.ChangeLogEntry(
            id: entryID,
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
            newAlbumName: newAlbumName
        )
    }
}
