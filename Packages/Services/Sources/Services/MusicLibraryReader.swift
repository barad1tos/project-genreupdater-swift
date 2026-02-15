// MusicLibraryReader.swift — MusicKit library access wrapper
// NEW: No Python equivalent (Python used AppleScript for everything)
//
// MusicKit provides type-safe, fast read access to the Music library.
// This replaces the Python `fetch_tracks.applescript` for READ operations.
// WRITE operations still go through AppleScriptBridge (MusicKit has no write API).
//
// MusicKit advantages over AppleScript reads:
// - 10-50x faster for large libraries (native framework vs IPC)
// - Type-safe Song/Album/Artist models
// - Async/await native
// - No parsing of delimited strings

import Core
import Foundation
import MusicKit
import OSLog

private let log = AppLogger.make(category: "music-reader")

// MARK: - Errors

public enum MusicLibraryError: Error, LocalizedError {
    case authorizationDenied
    case authorizationRestricted
    case fetchFailed(detail: String)
    case musicAppNotAvailable

    public var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            "Music library access was denied. "
                + "Please grant access in System Settings > "
                + "Privacy & Security > Media & Apple Music."
        case .authorizationRestricted:
            "Music library access is restricted on this device."
        case let .fetchFailed(detail):
            "Failed to read music library: \(detail)"
        case .musicAppNotAvailable:
            "Music app is not available on this system."
        }
    }
}

// MARK: - Music Library Reader

/// Reads the user's Music library via MusicKit framework.
///
/// Provides fast, type-safe access to tracks, albums, and artists.
/// For write operations (updating genre, year), use `AppleScriptBridge` instead —
/// MusicKit does not support writing metadata.
public actor MusicLibraryReader {
    public init() {}

    /// Request access to the user's music library.
    public func requestAuthorization() async throws {
        let status = await MusicAuthorization.request()
        switch status {
        case .authorized:
            log.info("Music library access authorized")
        case .denied:
            throw MusicLibraryError.authorizationDenied
        case .restricted:
            throw MusicLibraryError.authorizationRestricted
        case .notDetermined:
            log.warning("Music authorization not determined after request")
            throw MusicLibraryError.authorizationDenied
        @unknown default:
            log.warning("Unknown music authorization status: \(String(describing: status), privacy: .public)")
            throw MusicLibraryError.authorizationDenied
        }
    }

    /// Check current authorization status without triggering a prompt.
    public var isAuthorized: Bool {
        MusicAuthorization.currentStatus == .authorized
    }

    // MARK: - Fetch Operations

    /// Fetch all tracks from the user's library.
    public func fetchAllTracks(artist: String? = nil) async throws -> [Core.Track] {
        guard isAuthorized else {
            try await requestAuthorization()
            return try await fetchAllTracks(artist: artist)
        }

        var request = MusicLibraryRequest<Song>()
        request.sort(by: \.artistName, ascending: true)

        if let artist {
            request.filter(matching: \.artistName, equalTo: artist)
        }

        do {
            let response = try await request.response()
            let tracks = response.items.map { song in
                songToTrack(song)
            }
            log
                .info(
                    "Fetched \(tracks.count, privacy: .public) tracks from MusicKit\(artist.map { " (artist: \($0))" } ?? "", privacy: .private)"
                )
            return tracks
        } catch {
            log.error("MusicKit fetch failed: \(error.localizedDescription, privacy: .public)")
            throw MusicLibraryError.fetchFailed(detail: error.localizedDescription)
        }
    }

    /// Fetch a single track by its persistent ID.
    public func fetchTrack(byID id: String) async throws -> Core.Track? {
        let musicItemID = MusicItemID(id)

        var request = MusicLibraryRequest<Song>()
        request.filter(matching: \.id, equalTo: musicItemID)

        let response = try await request.response()
        return response.items.first.map { songToTrack($0) }
    }

    /// Get the total track count (fast, no full fetch needed).
    public func trackCount() async throws -> Int {
        let request = MusicLibraryRequest<Song>()
        let response = try await request.response()
        return response.items.count
    }

    // MARK: - Conversion

    /// Convert a MusicKit Song to our domain Track model.
    private func songToTrack(_ song: Song) -> Core.Track {
        Core.Track(
            id: song.id.rawValue,
            name: song.title,
            artist: song.artistName,
            album: song.albumTitle ?? "",
            genre: song.genreNames.first,
            year: song.releaseDate.map { Calendar.current.component(.year, from: $0) },
            dateAdded: song.libraryAddedDate,
            lastModified: nil,
            trackStatus: nil,
            albumArtist: nil
        )
    }
}
