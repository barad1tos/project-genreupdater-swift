import Foundation

/// Stable album-level identity for grouping, cache keys, and pending verification.
public struct AlbumIdentity: Sendable, Hashable, Codable {
    public let artist: String
    public let album: String

    public init(artist: String, album: String) {
        self.artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        self.album = album.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init(track: Track) {
        self.init(
            artist: Self.groupingArtist(for: track),
            album: track.album
        )
    }

    public var key: String {
        Self.key(artist: artist, album: album)
    }

    public var isComplete: Bool {
        !artist.isEmpty && !album.isEmpty
    }

    public static func key(for track: Track) -> String {
        Self(track: track).key
    }

    public static func key(artist: String, album: String) -> String {
        [
            normalizeForMatching(artist),
            normalizeForMatching(album),
        ].joined(separator: "\u{1F}")
    }

    public static func groupingArtist(for track: Track) -> String {
        let albumArtist = track.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let albumArtist, !albumArtist.isEmpty {
            return albumArtist
        }

        return extractMainArtist(track.artist)
    }
}

extension Track {
    public var albumIdentity: AlbumIdentity {
        AlbumIdentity(track: self)
    }
}
