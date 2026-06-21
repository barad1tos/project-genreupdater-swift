// Track.swift — Domain model for Music.app tracks
// Ported from: src/core/models/track_models.py (713 LOC → ~160 LOC)
//
// Key design decisions:
// - Plain struct (NOT @Model) — domain logic lives in Core which has no SwiftData dependency
// - Sendable — safe to pass across actor boundaries (concurrent processing)
// - Codable — serialization for cache, AppleScript parsing, snapshot persistence
// - Separate PersistedTrack @Model class lives in Services/Persistence/ for SwiftData
// - Year stored as Int? (not String?) — Swift's type system prevents year-as-string bugs

import Foundation

/// A track from the user's Apple Music library.
///
/// This is the primary domain model used throughout the app. It represents
/// the metadata of a single track as read from Music.app via MusicKit or AppleScript.
///
/// The struct is intentionally value-typed and Sendable so it can be freely
/// passed between actors (API orchestrator, cache service, UI layer) without
/// data races.
public struct Track: Sendable, Codable, Identifiable, Hashable {
    /// Music.app persistent track ID.
    public let id: String

    /// Track title.
    public var name: String

    /// Primary artist name.
    public var artist: String

    /// Album name.
    public var album: String

    /// Genre string (e.g., "Metal", "Electronic").
    public var genre: String?

    /// Release year as determined by the app or Music.app.
    public var year: Int?

    /// Date the track was added to the library.
    public var dateAdded: Date?

    /// Date the track was last modified in Music.app.
    public var lastModified: Date?

    /// Track availability status (see TrackKind).
    public var trackStatus: String?

    /// Original artist name before any renaming.
    public var originalArtist: String?

    /// Original album name before any cleaning.
    public var originalAlbum: String?

    /// Year value before the first Genre Updater modification.
    public var yearBeforeMGU: Int?

    /// Year that Genre Updater applied (for revert support).
    public var yearSetByMGU: Int?

    /// Release year from Music.app's release date field.
    public var releaseYear: Int?

    /// Original position in the track list (for sort stability).
    public var originalPosition: Int?

    /// Album artist for proper grouping of collaborations.
    public var albumArtist: String?

    public init(
        id: String,
        name: String,
        artist: String,
        album: String,
        genre: String? = nil,
        year: Int? = nil,
        dateAdded: Date? = nil,
        lastModified: Date? = nil,
        trackStatus: String? = nil,
        originalArtist: String? = nil,
        originalAlbum: String? = nil,
        yearBeforeMGU: Int? = nil,
        yearSetByMGU: Int? = nil,
        releaseYear: Int? = nil,
        originalPosition: Int? = nil,
        albumArtist: String? = nil
    ) {
        self.id = id
        self.name = name
        self.artist = artist
        self.album = album
        self.genre = genre
        self.year = year
        self.dateAdded = dateAdded
        self.lastModified = lastModified
        self.trackStatus = trackStatus
        self.originalArtist = originalArtist
        self.originalAlbum = originalAlbum
        self.yearBeforeMGU = yearBeforeMGU
        self.yearSetByMGU = yearSetByMGU
        self.releaseYear = releaseYear
        self.originalPosition = originalPosition
        self.albumArtist = albumArtist
    }

    // MARK: - Computed Properties

    /// Effective artist for grouping (prefers albumArtist if available).
    public var effectiveArtist: String {
        if let albumArtist, !albumArtist.isEmpty {
            return albumArtist
        }
        return artist
    }

    /// Whether this track has been processed by Genre Updater before.
    public var hasBeenProcessed: Bool {
        yearSetByMGU != nil || yearBeforeMGU != nil
    }

    /// The normalized TrackKind for this track's status.
    public var kind: TrackKind? {
        normalizeTrackStatus(trackStatus)
    }

    /// Whether this track's metadata can be edited.
    public var canEdit: Bool {
        kind?.canEditMetadata ?? true
    }
}

// MARK: - Change Log

/// A record of a metadata change applied to a track.
///
/// Used for change reports, undo/revert functionality, and audit trail.
public struct ChangeLogEntry: Sendable, Codable, Identifiable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let changeType: ChangeType
    public let trackID: String
    public let artist: String
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

    // Artist rename changes
    public var oldArtist: String?
    public var newArtist: String?

    public init(
        changeType: ChangeType,
        trackID: String,
        artist: String,
        trackName: String = "",
        albumName: String = ""
    ) {
        id = UUID()
        timestamp = .now
        self.changeType = changeType
        self.trackID = trackID
        self.artist = artist
        self.trackName = trackName
        self.albumName = albumName
    }

    /// Round-trip init for restoring from persistence (preserves original id and timestamp).
    public init(
        id: UUID,
        timestamp: Date,
        changeType: ChangeType,
        trackID: String,
        artist: String,
        trackName: String = "",
        albumName: String = "",
        oldGenre: String? = nil,
        newGenre: String? = nil,
        oldYear: Int? = nil,
        newYear: Int? = nil,
        oldTrackName: String? = nil,
        newTrackName: String? = nil,
        oldAlbumName: String? = nil,
        newAlbumName: String? = nil,
        oldArtist: String? = nil,
        newArtist: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.changeType = changeType
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
        self.oldArtist = oldArtist
        self.newArtist = newArtist
    }
}

/// Types of metadata changes the app can make.
public enum ChangeType: String, Sendable, Codable, CaseIterable {
    case genreUpdate = "genre_update"
    case yearUpdate = "year_update"
    case trackCleaning = "track_cleaning"
    case albumCleaning = "album_cleaning"
    case artistRename = "artist_rename"
    case yearRevert = "year_revert"
}

// MARK: - Track Parsing from AppleScript

extension Track {
    /// Field separator used in AppleScript output (ASCII Record Separator).
    public static let fieldSeparator: Character = "\u{1E}"

    /// Record separator used in AppleScript output (ASCII Group Separator).
    public static let recordSeparator: Character = "\u{1D}"

    /// Parse a track from AppleScript's delimited output.
    ///
    /// AppleScript returns tracks as fields separated by \x1E (Record Separator)
    /// with records separated by \x1D (Group Separator).
    ///
    /// Field order (from `serializeTrack` in fetch_tracks.applescript):
    /// [0] id, [1] name, [2] artist, [3] albumArtist, [4] album,
    /// [5] genre, [6] dateAdded, [7] modDate, [8] status,
    /// [9] year, [10] releaseYear, [11] empty placeholder
    ///
    /// - Parameter raw: Single record string from AppleScript output
    /// - Returns: Parsed Track, or nil if parsing fails
    public static func fromAppleScriptOutput(_ raw: String) -> Track? {
        let fields = raw.split(separator: fieldSeparator, omittingEmptySubsequences: false)
            .map(String.init)

        // Minimum fields: id, name, artist, albumArtist, album
        guard fields.count >= 5 else { return nil }

        return Track(
            id: fields[0],
            name: fields[1],
            artist: fields[2],
            album: fields[4],
            genre: fields.count > 5 ? fields[safe: 5]?.nilIfEmpty : nil,
            year: fields.count > 9 ? fields[safe: 9].flatMap { Int($0) } : nil,
            dateAdded: fields.count > 6 ? fields[safe: 6].flatMap { parseAppleScriptDate($0) } : nil,
            lastModified: fields.count > 7 ? fields[safe: 7].flatMap { parseAppleScriptDate($0) } : nil,
            trackStatus: fields.count > 8 ? fields[safe: 8]?.nilIfEmpty : nil,
            releaseYear: fields.count > 10 ? parseAppleScriptReleaseYear(fields[safe: 10]) : nil,
            albumArtist: fields.count > 3 ? fields[safe: 3]?.nilIfEmpty : nil
        )
    }
}

// MARK: - Helpers

// Safety: All formatters are configured once at init and never mutated afterward.
// They are effectively read-only after initialization, making concurrent access safe.
private enum AppleScriptDateFormatters {
    /// Compact format produced by our AppleScript `formatDate` handler: "2024-02-21 13:45:00"
    static let compact: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    // Safety: Configured once at init, never mutated — concurrent reads are safe.
    nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = .init()

    static let natural: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm:ss a"
        formatter.locale = Locale(identifier: "en_US")
        return formatter
    }()
}

private func parseAppleScriptDate(_ string: String) -> Date? {
    // Compact first — the format our scripts actually produce
    if let date = AppleScriptDateFormatters.compact.date(from: string) { return date }
    if let date = AppleScriptDateFormatters.iso8601.date(from: string) { return date }
    return AppleScriptDateFormatters.natural.date(from: string)
}

private func parseAppleScriptReleaseYear(_ string: String?) -> Int? {
    guard let value = string?.nilIfEmpty else { return nil }
    if let year = Int(value) { return year }
    guard let releaseDate = parseAppleScriptDate(value) else { return nil }
    return Calendar(identifier: .gregorian).component(.year, from: releaseDate)
}

extension Collection {
    public subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension String {
    public var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
