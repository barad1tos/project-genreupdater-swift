// PersistedTrack.swift — SwiftData model for track processing state
// Phase 2A: Persistence Layer

import Core
import Foundation
import SwiftData

/// Persistent representation of a track's processing state.
///
/// This is the SwiftData `@Model` counterpart to `Core.Track`.
/// It stores which tracks have been processed and what changes were made,
/// surviving app restarts and supporting 30K+ track libraries.
///
/// The domain model (`Core.Track`) remains a plain struct with no persistence
/// dependencies, keeping Core free of SwiftData.
@Model
public final class PersistedTrack {
    @Attribute(.unique)
    public var trackID: String

    public var name: String
    public var artist: String
    public var album: String
    public var genre: String?
    public var year: Int?
    public var genreUpdated: Bool
    public var yearUpdated: Bool
    public var processedDate: Date?
    public var lastError: String?
    public var dateAdded: Date?
    public var albumArtist: String?
    public var trackStatus: String?
    public var releaseYear: Int?

    @Relationship(deleteRule: .cascade, inverse: \PersistedChangeLogEntry.track)
    public var changeLog: [PersistedChangeLogEntry] = []

    public init(
        trackID: String,
        name: String,
        artist: String,
        album: String,
        genre: String? = nil,
        year: Int? = nil,
        genreUpdated: Bool = false,
        yearUpdated: Bool = false,
        processedDate: Date? = nil,
        lastError: String? = nil,
        dateAdded: Date? = nil,
        albumArtist: String? = nil,
        trackStatus: String? = nil,
        releaseYear: Int? = nil
    ) {
        self.trackID = trackID
        self.name = name
        self.artist = artist
        self.album = album
        self.genre = genre
        self.year = year
        self.genreUpdated = genreUpdated
        self.yearUpdated = yearUpdated
        self.processedDate = processedDate
        self.lastError = lastError
        self.dateAdded = dateAdded
        self.albumArtist = albumArtist
        self.trackStatus = trackStatus
        self.releaseYear = releaseYear
    }
}

// MARK: - Conversion to/from Core.Track

extension PersistedTrack {
    /// Create a persisted track from a domain track.
    public convenience init(from track: Core.Track) {
        self.init(
            trackID: track.id,
            name: track.name,
            artist: track.artist,
            album: track.album,
            genre: track.genre,
            year: track.year,
            dateAdded: track.dateAdded,
            albumArtist: track.albumArtist,
            trackStatus: track.trackStatus,
            releaseYear: track.releaseYear
        )
    }

    /// Convert to the domain Track model.
    public func toTrack() -> Core.Track {
        Core.Track(
            id: trackID,
            name: name,
            artist: artist,
            album: album,
            genre: genre,
            year: year,
            dateAdded: dateAdded,
            trackStatus: trackStatus,
            releaseYear: releaseYear,
            albumArtist: albumArtist
        )
    }

    /// Update this persisted track from a domain track (preserving processing state).
    public func update(from track: Core.Track) {
        name = track.name
        artist = track.artist
        album = track.album
        genre = track.genre
        year = track.year
        dateAdded = track.dateAdded
        albumArtist = track.albumArtist
        trackStatus = track.trackStatus
        releaseYear = track.releaseYear
    }
}
