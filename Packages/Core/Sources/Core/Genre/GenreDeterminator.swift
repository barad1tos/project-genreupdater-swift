// GenreDeterminator.swift — Dominant genre from earliest album
// Port of: metadata_utils.py determine_dominant_genre_for_artist()
//
// Algorithm: find the earliest track (by dateAdded) per album,
// then find the absolute earliest across albums — return its genre.
// No API calls or weighted voting; an optional user mapping may transform the result.

import Foundation
import OSLog

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
///    Equal dates preserve the first album's position in the input.
/// 4. Return that track's genre (as-is before an optional mapping).
/// 5. If genre is nil or empty, return nil.
public struct GenreDeterminator: Sendable {
    public init() {}

    /// Determine dominant genre for an artist from their tracks.
    ///
    /// - Parameter artistTracks: All tracks for a single artist.
    /// - Returns: Genre result with the dominant genre and source info.
    public func determineDominantGenre(
        artistTracks: [Track]
    ) -> GenreResult {
        determineDominantGenre(artistTracks: artistTracks, genreMappings: [:])
    }

    /// Determine dominant genre for an artist, applying user-defined genre mappings.
    ///
    /// After the standard earliest-album algorithm determines a genre, the result
    /// is checked against `genreMappings`. Lookup trims sources and is case-insensitive;
    /// a nonblank mapped value preserves its trimmed case. Conflicting targets fail closed
    /// to the original genre when callers bypass configuration validation.
    ///
    /// - Parameters:
    ///   - artistTracks: All tracks for a single artist.
    ///   - genreMappings: User-defined source-to-target genre replacements.
    /// - Returns: Genre result with the (possibly remapped) dominant genre.
    public func determineDominantGenre(
        artistTracks: [Track],
        genreMappings: [String: String]
    ) -> GenreResult {
        guard !artistTracks.isEmpty else {
            return GenreResult(genre: nil)
        }

        let signpostState = AppSignpost.genreDetermination.beginInterval("determineDominantGenre")
        defer { AppSignpost.genreDetermination.endInterval("determineDominantGenre", signpostState) }

        // Step 1: Find the earliest track per album
        let albumEarliest = earliestAlbumTracks(in: artistTracks)

        guard !albumEarliest.isEmpty else {
            return GenreResult(genre: nil)
        }

        // Step 2: Find the earliest track across all albums
        guard let earliestTrack = earliestTrack(in: albumEarliest) else {
            return GenreResult(genre: nil)
        }

        // Step 3: Extract genre (nil if track has no genre)
        guard let genre = extractGenre(from: earliestTrack) else {
            return GenreResult(genre: nil)
        }

        // Step 4: Apply user-defined genre mapping (case-insensitive lookup)
        let mappedGenre = Self.applyGenreMapping(genre, mappings: genreMappings)

        return GenreResult(
            genre: mappedGenre,
            sourceAlbum: earliestTrack.album,
            sourceTrackDateAdded: earliestTrack.dateAdded
        )
    }

    /// Look up a genre in user-defined mappings after trimming and case normalization.
    ///
    /// - Parameters:
    ///   - genre: The determined genre to look up.
    ///   - mappings: Source-to-target genre dictionary.
    /// - Returns: The unique nonblank mapped genre, or the original genre when no safe mapping exists.
    static func applyGenreMapping(
        _ genre: String,
        mappings: [String: String]
    ) -> String {
        let normalizedGenre = normalizeForMatching(genre)
        guard !normalizedGenre.isEmpty else { return genre }

        let targets = Set(mappings.compactMap { source, target -> String? in
            guard normalizeForMatching(source) == normalizedGenre else { return nil }
            let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedTarget.isEmpty ? nil : trimmedTarget
        })
        guard targets.count == 1, let target = targets.first else { return genre }
        return target
    }

    // MARK: - Private Helpers

    /// Find the earliest track (by dateAdded) for each album.
    ///
    /// Tracks with empty album names or nil dateAdded are skipped,
    /// matching the Python behavior.
    private func earliestAlbumTracks(in tracks: [Track]) -> [Track] {
        var albumIndexes: [String: Int] = [:]
        var earliestTracks: [Track] = []

        for track in tracks {
            let album = track.album
            guard !album.isEmpty else { continue }
            guard let trackDate = track.dateAdded else { continue }

            if let albumIndex = albumIndexes[album],
               let existingDate = earliestTracks[albumIndex].dateAdded,
               trackDate < existingDate {
                earliestTracks[albumIndex] = track
            } else if albumIndexes[album] == nil {
                albumIndexes[album] = earliestTracks.count
                earliestTracks.append(track)
            }
        }

        return earliestTracks
    }

    /// Find the track with the earliest dateAdded across all album representatives.
    private func earliestTrack(in albumTracks: [Track]) -> Track? {
        var earliestTrack: Track?
        var earliestDate: Date?

        for track in albumTracks {
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
    /// Python parity: returns nil if genre is nil or empty.
    private func extractGenre(from track: Track) -> String? {
        guard let genre = track.genre, !genre.isEmpty else {
            return nil
        }
        return genre
    }
}
