import Core
import Foundation
import OSLog

extension LibrarySyncService {
    struct MutationMetadataFetch {
        let tracks: [Track]
        let absenceEligibleMusicKitIDs: Set<String>
    }

    private static let readProviderLogger = Logger(
        subsystem: "com.genreupdater",
        category: "LibrarySyncService"
    )

    func logReadProviderSyncResult(_ result: SyncResult) {
        Self.readProviderLogger
            .info(
                """
                MusicKit sync detected: \(result.newTracks.count, privacy: .public) new, \
                \(result.modifiedTracks.count, privacy: .public) modified, \
                \(result.identityChangedTracks.count, privacy: .public) identity changed, \
                \(result.refreshedTracks.count, privacy: .public) refreshed, \
                \(result.removedTrackIDs.count, privacy: .public) removed
                """
            )
    }

    func readProviderPersistenceTrack(
        current: Track,
        stored: Track,
        appleScriptMetadata: Track? = nil,
        isAppleScriptMetadataAuthoritative: Bool = false
    ) -> Track {
        // Full AppleScript reads are authoritative for writable metadata; mapper enrichment can be partial.
        let genre = isAppleScriptMetadataAuthoritative
            ? appleScriptMetadata.map(\.genre) ?? stored.genre ?? current.genre
            : appleScriptMetadata?.genre ?? stored.genre ?? current.genre
        let year = isAppleScriptMetadataAuthoritative
            ? appleScriptMetadata.map(\.year) ?? stored.year
            : appleScriptMetadata?.year ?? stored.year
        let releaseYear = isAppleScriptMetadataAuthoritative
            ? appleScriptMetadata.map(\.releaseYear) ?? stored.releaseYear ?? current.releaseYear
            : appleScriptMetadata?.releaseYear ?? stored.releaseYear ?? current.releaseYear
        let albumArtist = isAppleScriptMetadataAuthoritative
            ? appleScriptMetadata.map(\.albumArtist) ?? stored.albumArtist ?? current.albumArtist
            : appleScriptMetadata?.albumArtist ?? stored.albumArtist ?? current.albumArtist

        return Track(
            id: current.id,
            name: current.name,
            artist: current.artist,
            album: current.album,
            genre: genre,
            year: year,
            dateAdded: current.dateAdded ?? stored.dateAdded,
            lastModified: appleScriptMetadata?.lastModified ?? current.lastModified ?? stored.lastModified,
            trackStatus: appleScriptMetadata?.trackStatus ?? stored.trackStatus,
            originalArtist: current.originalArtist ?? stored.originalArtist,
            originalAlbum: current.originalAlbum ?? stored.originalAlbum,
            yearBeforeMGU: current.yearBeforeMGU ?? stored.yearBeforeMGU,
            yearSetByMGU: current.yearSetByMGU ?? stored.yearSetByMGU,
            releaseYear: releaseYear,
            originalPosition: current.originalPosition ?? stored.originalPosition,
            albumArtist: albumArtist,
            appleScriptID: appleScriptMetadata?.appleScriptID ?? current.appleScriptID ?? stored.appleScriptID
        )
    }

    func hasDisplayMetadataChanged(current: Track, stored: Track) -> Bool {
        // lastModified is AppleScript-only today; using it here would refresh the same SwiftData rows forever.
        current.name != stored.name
            || current.artist != stored.artist
            || current.album != stored.album
            || current.albumArtist != stored.albumArtist
            || current.dateAdded != stored.dateAdded
    }

    func hasIdentityChanged(current: Track, stored: Track) -> Bool {
        Set(AlbumIdentity.lookupKeys(for: current)) != Set(AlbumIdentity.lookupKeys(for: stored))
    }

    func readProviderPresenceKeys(for track: Track) -> [String] {
        readProviderIdentityKeys(for: track) { name, artist in
            [
                "\(name)|\(artist)|\(track.album.lowercased())",
                "\(name)|\(artist)",
            ]
        }
    }

    func mutationMetadataArtistScopes(for tracks: [Track]) -> [String] {
        var seenKeys: Set<String> = []
        var artists: [String] = []
        for track in tracks {
            let candidates = [track.artist, track.albumArtist ?? ""]
            for candidate in candidates {
                let artist = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !artist.isEmpty else { continue }

                let key = artist.lowercased()
                guard seenKeys.insert(key).inserted else { continue }
                artists.append(artist)
            }
        }
        return artists.sorted()
    }

    func hasMutationMetadataScopeLessCandidates(for tracks: [Track]) -> Bool {
        tracks.contains { track in
            [track.artist, track.albumArtist ?? ""].allSatisfy {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }

    func mutationMetadataAbsenceEligibleTrackIDs(for tracks: [Track], artist: String) -> Set<String> {
        let scopeKey = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Set(tracks.compactMap { track in
            let candidates = [track.artist, track.albumArtist ?? ""]
            let hasQueriedScope = candidates.contains { candidate in
                candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == scopeKey
            }
            return hasQueriedScope ? track.id : nil
        })
    }

    func fetchFullLibraryMutationMetadata(for tracks: [Track]) async throws -> MutationMetadataFetch {
        let appleScriptTrackIDs = try await scriptBridge.fetchAllTrackIDs(
            timeout: runtimeConfiguration.fullLibraryFetchTimeout
        )
        guard !appleScriptTrackIDs.isEmpty else {
            return MutationMetadataFetch(tracks: [], absenceEligibleMusicKitIDs: [])
        }
        let appleScriptTracks = try await scriptBridge.fetchTracksByIDs(
            appleScriptTrackIDs,
            batchSize: runtimeConfiguration.idsBatchSize,
            timeout: runtimeConfiguration.idsBatchFetchTimeout
        )
        return MutationMetadataFetch(
            tracks: appleScriptTracks,
            absenceEligibleMusicKitIDs: Set(tracks.map(\.id))
        )
    }

    func cacheInvalidationTargets(for track: Track) -> [(artist: String, album: String)] {
        AlbumIdentity.lookupCandidates(for: track).map { identity in
            (artist: identity.artist, album: identity.album)
        }
    }

    static func isPrereleasePendingReason(_ reason: String) -> Bool {
        let normalizedReason = reason
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
        return normalizedReason == "prerelease" || normalizedReason == "pre_release"
    }

    func hasPrereleaseTrack(in tracks: [Track], artist: String, album: String) -> Bool {
        let targetKeys = Set(AlbumIdentity.lookupKeys(artist: artist, album: album))
        return tracks.contains { track in
            guard track.kind == .prerelease else { return false }
            let trackKeys = Set(AlbumIdentity.lookupKeys(for: track))
            return !targetKeys.isDisjoint(with: trackKeys)
        }
    }

    func normalizedCacheInvalidationTargets(
        _ candidates: [(artist: String, album: String)]
    ) -> [(artist: String, album: String)] {
        var seenKeys: Set<String> = []
        return candidates.compactMap { candidate in
            let artist = candidate.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            let album = candidate.album.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !artist.isEmpty, !album.isEmpty else { return nil }

            let key = "\(normalizeForMatching(artist))\u{1F}\(normalizeForMatching(album))"
            guard seenKeys.insert(key).inserted else { return nil }
            return (artist: artist, album: album)
        }
    }

    private func readProviderIdentityKeys(
        for track: Track,
        _ buildKeys: (_ name: String, _ artist: String) -> [String]
    ) -> [String] {
        let albumArtist = track.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines)
        var artistValues = [track.artist]
        if let albumArtist, !albumArtist.isEmpty {
            artistValues.append(albumArtist)
        }

        let name = track.name.lowercased()
        var keys: [String] = []
        var seenKeys: Set<String> = []
        for artist in artistValues {
            for key in buildKeys(name, artist.lowercased()) {
                guard seenKeys.insert(key).inserted else { continue }
                keys.append(key)
            }
        }
        return keys
    }

    static func resolvedURL(path: String, relativeTo baseURL: URL? = nil) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let appSupport = defaultDirectory().path
        var expandedPath = path
            .replacingOccurrences(of: "${APP_SUPPORT}", with: appSupport)
            .replacingOccurrences(of: "${HOME}", with: home)
            .replacingOccurrences(of: "$HOME", with: home)
        if expandedPath == "~" {
            expandedPath = home
        } else if expandedPath.hasPrefix("~/") {
            expandedPath = home + String(expandedPath.dropFirst())
        }

        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath)
        }
        return (baseURL ?? FileManager.default.temporaryDirectory).appendingPathComponent(expandedPath)
    }

    static func defaultDirectory() -> URL {
        let directories = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )
        guard let appSupport = directories.first else {
            return URL(fileURLWithPath: NSTemporaryDirectory())
        }
        return appSupport.appendingPathComponent("GenreUpdater", isDirectory: true)
    }
}
