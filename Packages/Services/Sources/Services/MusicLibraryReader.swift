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
    private var testArtists: [String]

    /// - Parameter testArtists: When non-empty, `fetchAllTracks` returns
    ///   only tracks whose `effectiveArtist` matches one of these names
    ///   (case-insensitive). Pass an empty array to disable filtering.
    public init(testArtists: [String] = []) {
        self.testArtists = testArtists
    }

    public func updateTestArtists(_ testArtists: [String]) {
        self.testArtists = testArtists
    }

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
    public func fetchAllTracks(
        artist: String? = nil,
        ignoreTestFilter: Bool = false
    ) async throws -> [Core.Track] {
        guard isAuthorized else {
            try await requestAuthorization()
            return try await fetchAllTracks(
                artist: artist,
                ignoreTestFilter: ignoreTestFilter
            )
        }

        let signpostState = AppSignpost.libraryLoad.beginInterval("fetchAllTracks")
        defer { AppSignpost.libraryLoad.endInterval("fetchAllTracks", signpostState) }

        do {
            var tracks: [Core.Track] = []
            let targets = Self.fetchTargets(
                requestedArtist: artist,
                testArtists: testArtists,
                ignoreTestFilter: ignoreTestFilter
            )

            for target in targets {
                let scopedTracks = try await fetchTracks(matchingArtist: target)
                tracks.append(contentsOf: scopedTracks)
            }

            if !ignoreTestFilter {
                tracks = Self.filterByTestArtists(
                    tracks,
                    testArtists: testArtists
                )
            }

            log
                .info(
                    "Fetched \(tracks.count, privacy: .public) tracks from MusicKit\(artist.map { " (artist: \($0))" } ?? "", privacy: .private)"
                )
            return tracks
        } catch is CancellationError {
            throw CancellationError()
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

    // MARK: - Test Artist Filtering

    /// Resolve MusicKit fetch targets for a requested artist and active test
    /// artist scope.
    public static func fetchTargets(
        requestedArtist: String?,
        testArtists: [String],
        ignoreTestFilter: Bool
    ) -> [String?] {
        if let artist = normalizedArtistName(requestedArtist) {
            return [artist]
        }

        guard !ignoreTestFilter else { return [nil] }

        let scopedArtists = uniqueArtistNames(testArtists)
        guard !scopedArtists.isEmpty else { return [nil] }
        return scopedArtists.map(Optional.some)
    }

    /// Filter tracks to only those whose `effectiveArtist` matches
    /// one of the given test artist names (case-insensitive).
    ///
    /// Returns the original array unmodified when `testArtists` is empty.
    /// Exposed as `static` so the logic is testable without MusicKit.
    ///
    /// - Parameters:
    ///   - tracks: The full set of tracks to filter.
    ///   - testArtists: Artist names to keep. Empty means no filtering.
    /// - Returns: Filtered tracks, or the original array if `testArtists`
    ///   is empty.
    public static func filterByTestArtists(
        _ tracks: [Core.Track],
        testArtists: [String]
    ) -> [Core.Track] {
        guard !testArtists.isEmpty else { return tracks }
        return tracks.filter { track in
            testArtists.contains { name in
                name.localizedCaseInsensitiveCompare(
                    track.effectiveArtist
                ) == .orderedSame
            }
        }
    }

    private static func normalizedArtistName(_ artist: String?) -> String? {
        let trimmedArtist = artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedArtist.isEmpty ? nil : trimmedArtist
    }

    private static func uniqueArtistNames(_ artists: [String]) -> [String] {
        var uniqueArtists: [String] = []

        for artist in artists {
            guard let trimmedArtist = normalizedArtistName(artist) else { continue }
            let alreadyIncluded = uniqueArtists.contains { existingArtist in
                existingArtist.localizedCaseInsensitiveCompare(trimmedArtist) == .orderedSame
            }
            if !alreadyIncluded {
                uniqueArtists.append(trimmedArtist)
            }
        }

        return uniqueArtists
    }

    private func fetchTracks(matchingArtist artist: String?) async throws -> [Core.Track] {
        var request = MusicLibraryRequest<Song>()
        request.sort(by: \.artistName, ascending: true)

        if let artist {
            request.filter(matching: \.artistName, equalTo: artist)
        }

        let response = try await request.response()
        return response.items.map { song in
            songToTrack(song)
        }
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
