import Core
import Foundation

extension LibrarySyncService {
    func hasIdentityChanged(current: Track, stored: Track) -> Bool {
        Set(AlbumIdentity.lookupKeys(for: current)) != Set(AlbumIdentity.lookupKeys(for: stored))
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
