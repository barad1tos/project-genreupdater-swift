// GenreDeterminator.swift — Dominant genre from earliest album
// Port of: metadata_utils.py determine_dominant_genre_for_artist()
//
// Algorithm: find the earliest track (by dateAdded) per album,
// then find the absolute earliest across albums — return its genre.
// No API calls, no mapping, no weighted voting.

import Foundation

// MARK: - Result Type

/// Result of genre determination.
public struct GenreResult: Sendable, Equatable {
    /// The determined genre, or nil if no valid genre found.
    public let genre: String?

    /// Album name of the source track (for diagnostics).
    public let sourceAlbum: String?

    /// dateAdded of the source track (for diagnostics).
    public let sourceTrackDateAdded: Date?

    public init(
        genre: String?,
        sourceAlbum: String? = nil,
        sourceTrackDateAdded: Date? = nil
    ) {
        self.genre = genre
        self.sourceAlbum = sourceAlbum
        self.sourceTrackDateAdded = sourceTrackDateAdded
    }
}

// MARK: - GenreDeterminator

/// Determines the dominant genre for an artist from their library tracks.
///
/// Port of Python `determine_dominant_genre_for_artist()`.
/// Algorithm:
/// 1. Group tracks by album (skip tracks with empty album or nil dateAdded).
/// 2. For each album, find the track with the earliest `dateAdded`.
/// 3. Among those earliest-per-album tracks, find the absolute earliest.
/// 4. Return that track's genre (as-is, no normalization).
/// 5. If genre is nil or empty, return "Unknown".
public struct GenreDeterminator: Sendable {
    public init() {}

    /// Determine dominant genre for an artist from their tracks.
    ///
    /// - Parameter artistTracks: All tracks for a single artist.
    /// - Returns: Genre result with the dominant genre and source info.
    public func determineDominantGenre(
        artistTracks: [Track]
    ) -> GenreResult {
        guard !artistTracks.isEmpty else {
            return GenreResult(genre: nil)
        }

        // Step 1: Find the earliest track per album
        let albumEarliest = getEarliestTrackPerAlbum(artistTracks)

        guard !albumEarliest.isEmpty else {
            return GenreResult(genre: nil)
        }

        // Step 2: Find the earliest track across all albums
        guard let earliestTrack = getEarliestTrackAcrossAlbums(albumEarliest) else {
            return GenreResult(genre: nil)
        }

        // Step 3: Extract genre
        let genre = extractGenre(from: earliestTrack)

        return GenreResult(
            genre: genre,
            sourceAlbum: earliestTrack.album,
            sourceTrackDateAdded: earliestTrack.dateAdded
        )
    }

    // MARK: - Private Helpers

    /// Find the earliest track (by dateAdded) for each album.
    ///
    /// Tracks with empty album names or nil dateAdded are skipped,
    /// matching the Python behavior.
    private func getEarliestTrackPerAlbum(_ tracks: [Track]) -> [String: Track] {
        var albumEarliest: [String: Track] = [:]

        for track in tracks {
            let album = track.album
            guard !album.isEmpty else { continue }
            guard let trackDate = track.dateAdded else { continue }

            if let existing = albumEarliest[album],
               let existingDate = existing.dateAdded {
                if trackDate < existingDate {
                    albumEarliest[album] = track
                }
            } else {
                albumEarliest[album] = track
            }
        }

        return albumEarliest
    }

    /// Find the track with the earliest dateAdded across all album representatives.
    private func getEarliestTrackAcrossAlbums(_ albumEarliest: [String: Track]) -> Track? {
        var earliestTrack: Track?
        var earliestDate: Date?

        for track in albumEarliest.values {
            guard let trackDate = track.dateAdded else { continue }

            if let currentEarliest = earliestDate {
                if trackDate < currentEarliest {
                    earliestDate = trackDate
                    earliestTrack = track
                }
            } else {
                earliestDate = trackDate
                earliestTrack = track
            }
        }

        return earliestTrack
    }

    /// Extract genre string from a track.
    ///
    /// Returns "Unknown" if genre is nil or empty (matches Python behavior).
    private func extractGenre(from track: Track) -> String {
        guard let genre = track.genre, !genre.isEmpty else {
            return "Unknown"
        }
        return genre
    }
}
