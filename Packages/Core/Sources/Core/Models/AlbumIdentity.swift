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

    public static func lookupCandidates(for track: Track) -> [Self] {
        lookupCandidates(
            artists: [
                groupingArtist(for: track),
                track.effectiveArtist,
                track.artist,
                explicitPrimaryArtist(track.artist),
            ],
            album: track.album
        )
    }

    public static func lookupCandidates(artist: String, album: String) -> [Self] {
        lookupCandidates(
            artists: [
                artist,
                explicitPrimaryArtist(artist),
            ],
            album: album
        )
    }

    public static func lookupKeys(for track: Track) -> [String] {
        lookupCandidates(for: track).map(\.key)
    }

    public static func lookupKeys(artist: String, album: String) -> [String] {
        lookupCandidates(artist: artist, album: album).map(\.key)
    }

    public static func groupingArtist(for track: Track) -> String {
        let albumArtist = track.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let albumArtist, !albumArtist.isEmpty {
            return albumArtist
        }

        return explicitPrimaryArtist(track.artist)
    }

    public static func primaryArtist(for track: Track) -> String {
        explicitPrimaryArtist(track.artist)
    }

    private static func lookupCandidates(artists: [String], album: String) -> [Self] {
        var seenKeys: Set<String> = []
        return artists.compactMap { artist in
            let identity = Self(artist: artist, album: album)
            guard identity.isComplete, seenKeys.insert(identity.key).inserted else {
                return nil
            }
            return identity
        }
    }

    private static func explicitPrimaryArtist(_ artist: String) -> String {
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        for separator in explicitFeatureSeparators {
            if let range = trimmed.range(of: separator, options: .caseInsensitive) {
                let primaryArtist = trimmed[trimmed.startIndex ..< range.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return primaryArtist.isEmpty ? trimmed : primaryArtist
            }
        }

        return trimmed
    }

    private static let explicitFeatureSeparators = [
        " feat. ",
        " feat ",
        " ft. ",
        " ft ",
        " featuring ",
    ]
}

extension Track {
    public var albumIdentity: AlbumIdentity {
        AlbumIdentity(track: self)
    }
}
