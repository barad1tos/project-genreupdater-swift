import Foundation

/// Stable album-level identity for grouping, cache keys, reports, and pending verification.
public struct AlbumIdentity: Sendable, Hashable, Codable {
    /// Canonical artist used for album-level decisions.
    public let artist: String
    /// Canonical album title used for album-level decisions.
    public let album: String

    private enum CodingKeys: String, CodingKey {
        case artist
        case album
    }

    /// Creates an identity from already-resolved artist and album values.
    public init(artist: String, album: String) {
        self.artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        self.album = album.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decodes a persisted identity and reapplies the canonical trimming rules.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            artist: container.decode(String.self, forKey: .artist),
            album: container.decode(String.self, forKey: .album)
        )
    }

    /// Encodes the canonical display values for persistence.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(artist, forKey: .artist)
        try container.encode(album, forKey: .album)
    }

    /// Compares album identities by their normalized stable key.
    public static func == (leftIdentity: Self, rightIdentity: Self) -> Bool {
        leftIdentity.key == rightIdentity.key
    }

    /// Hashes the normalized stable key so lookup containers share workflow identity semantics.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(key)
    }

    /// Creates an identity from writable track metadata.
    ///
    /// `albumArtist` wins when present because it is the strongest Music.app album-level grouping signal.
    /// Without it, explicit feature suffixes such as `feat.` or `featuring` are stripped from the track artist.
    public init(track: Track) {
        self.init(
            artist: Self.groupingArtist(for: track),
            album: track.album
        )
    }

    /// Normalized stable key used for dictionary grouping and cache lookup.
    public var key: String {
        Self.key(artist: artist, album: album)
    }

    /// Whether both artist and album are non-empty after trimming.
    public var isComplete: Bool {
        !artist.isEmpty && !album.isEmpty
    }

    /// Returns the canonical grouping key for a track.
    public static func key(for track: Track) -> String {
        Self(track: track).key
    }

    /// Returns the normalized lookup key for an artist and album pair.
    public static func key(artist: String, album: String) -> String {
        [
            normalizeForMatching(artist),
            normalizeForMatching(album),
        ].joined(separator: "\u{1F}")
    }

    /// Returns canonical and legacy lookup identities for a track.
    ///
    /// The first candidate is the canonical album identity. Later candidates preserve legacy caches and pending
    /// rows that may have been written under effective artist, raw artist, or a feature-stripped artist.
    /// Split-artist aliases exist ONLY when albumArtist is absent: with an album artist present the
    /// shield applies to lookups too — a "Simon & Garfunkel" album must never query rows for "Simon".
    public static func lookupCandidates(for track: Track) -> [Self] {
        var artists = [
            groupingArtist(for: track),
            track.effectiveArtist,
            track.artist,
        ]
        let albumArtist = track.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if albumArtist.isEmpty {
            artists.append(explicitPrimaryArtist(track.artist))
            artists.append(legacyFeatureArtist(track.artist))
        }
        return lookupCandidates(artists: artists, album: track.album)
    }

    /// Returns canonical and legacy lookup identities for a raw artist and album pair.
    /// A raw pair has no album-artist shield, so the split aliases always apply.
    public static func lookupCandidates(artist: String, album: String) -> [Self] {
        lookupCandidates(
            artists: [
                artist,
                explicitPrimaryArtist(artist),
                legacyFeatureArtist(artist),
            ],
            album: album
        )
    }

    /// Returns normalized lookup keys for all track-side identity aliases.
    public static func lookupKeys(for track: Track) -> [String] {
        lookupCandidates(for: track).map(\.key)
    }

    /// Returns normalized lookup keys for all raw artist identity aliases.
    public static func lookupKeys(artist: String, album: String) -> [String] {
        lookupCandidates(artist: artist, album: album).map(\.key)
    }

    /// Returns the preferred album-level artist for grouping and cache writes.
    public static func groupingArtist(for track: Track) -> String {
        let albumArtist = track.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let albumArtist, !albumArtist.isEmpty {
            return albumArtist
        }

        return explicitPrimaryArtist(track.artist)
    }

    /// Returns the track artist with explicit feature suffixes removed.
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

    /// Verbatim port of Python's normalize_collaboration_artist
    /// (year_utils.py): the separator LIST ORDER decides (not string
    /// position), matching is case-sensitive, the left side of the first
    /// listed separator wins. Deliberate divergences, both pathological
    /// edge inputs only: the input is trimmed FIRST, so a leading or
    /// trailing separator fragment (" & Friends", "A & ") no longer
    /// matches where Python would return "" or "A"; and the empty-left
    /// fallback below keeps the whole artist as a defensive floor.
    private static func explicitPrimaryArtist(_ artist: String) -> String {
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        for separator in collaborationSeparators {
            if let range = trimmed.range(of: separator) {
                let primaryArtist = trimmed[trimmed.startIndex ..< range.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return primaryArtist.isEmpty ? trimmed : primaryArtist
            }
        }

        return trimmed
    }

    private static let collaborationSeparators = [
        " & ",
        " feat. ",
        " feat ",
        " ft. ",
        " ft ",
        " vs. ",
        " vs ",
        " with ",
        " and ",
        " x ",
        " X ",
    ]

    /// The RETIRED pre-parity splitter (feat family + " featuring ",
    /// case-insensitive): album-year and pending rows persisted before the
    /// Python-parity switch were written under ITS output, so it survives
    /// as a lookup alias only — never as a producer of new identities.
    private static func legacyFeatureArtist(_ artist: String) -> String {
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        for separator in legacyFeatureSeparators {
            if let range = trimmed.range(of: separator, options: .caseInsensitive) {
                let primaryArtist = trimmed[trimmed.startIndex ..< range.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return primaryArtist.isEmpty ? trimmed : primaryArtist
            }
        }

        return trimmed
    }

    private static let legacyFeatureSeparators = [
        " feat. ",
        " feat ",
        " ft. ",
        " ft ",
        " featuring ",
    ]
}

extension Track {
    /// Album identity derived from the track's writable Music.app metadata.
    public var albumIdentity: AlbumIdentity {
        AlbumIdentity(track: self)
    }
}
