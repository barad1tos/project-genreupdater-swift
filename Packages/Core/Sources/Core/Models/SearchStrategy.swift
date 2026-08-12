import Foundation

/// How to FIND a year in the first place (query rewriting), as opposed to
/// AlbumType's how-to-HANDLE-a-year-once-found. Python's detection order is
/// preserved: soundtrack → Various Artists → unusual brackets → normal,
/// first match wins, and rewriting runs only after an empty standard aggregate.
/// Documented Swift divergences remain explicit beside the affected helpers.
public enum SearchStrategy: String, Sendable, Equatable {
    case normal
    case soundtrack
    case variousArtists
    case stripBrackets
}

public struct SearchStrategyInfo: Sendable, Equatable {
    public let strategy: SearchStrategy
    public let detectedPattern: String?
    public let modifiedArtist: String?
    public let modifiedAlbum: String?

    public init(
        strategy: SearchStrategy,
        detectedPattern: String? = nil,
        modifiedArtist: String? = nil,
        modifiedAlbum: String? = nil
    ) {
        self.strategy = strategy
        self.detectedPattern = detectedPattern
        self.modifiedArtist = modifiedArtist
        self.modifiedAlbum = modifiedAlbum
    }
}

/// The Python module's built-in pattern sets. Callers seed these when no
/// configuration exists; an explicitly EMPTY configured list stays empty
/// and disables the detection (Python's is-not-None semantics).
public enum SearchStrategyDefaults {
    public static let soundtrackPatterns = MetadataRuleDefaults.soundtracks
    public static let variousArtistsNames = MetadataRuleDefaults.variousArtists
}

/// Short tags like [CD1] are normal; longer content like
/// [MESSAGE FROM THE CLERGY] is unusual (Python threshold).
private let unusualBracketMinLength = 10

private let normalBracketContent = MetadataRuleDefaults.normalBrackets

public func detectSearchStrategy(
    artist: String,
    album: String,
    soundtrackPatterns: [String],
    variousArtistsNames: [String]
) -> SearchStrategyInfo {
    guard !album.isEmpty else {
        return SearchStrategyInfo(strategy: .normal)
    }

    if let info = soundtrackStrategy(album: album, patterns: soundtrackPatterns) {
        return info
    }
    if isVariousArtists(artist: artist, names: variousArtistsNames) {
        return SearchStrategyInfo(
            strategy: .variousArtists,
            detectedPattern: artist,
            modifiedAlbum: album
        )
    }
    if let stripped = unusualBracketStrip(album: album) {
        return SearchStrategyInfo(
            strategy: .stripBrackets,
            detectedPattern: "brackets",
            modifiedArtist: artist,
            modifiedAlbum: stripped
        )
    }
    return SearchStrategyInfo(strategy: .normal)
}

private func soundtrackStrategy(album: String, patterns: [String]) -> SearchStrategyInfo? {
    let albumLower = album.lowercased()
    guard let pattern = patterns.first(where: { albumLower.contains($0.lowercased()) }) else {
        return nil
    }

    if let range = albumLower.range(of: pattern.lowercased()),
       range.lowerBound != albumLower.startIndex {
        // lowercased() preserves grapheme counts for all known Unicode
        // data; limitedBy is the free hardening against the theoretical
        // expansion case (a miss falls back to no-rewrite).
        guard let prefixEnd = album.index(
            album.startIndex,
            offsetBy: albumLower.distance(from: albumLower.startIndex, to: range.lowerBound),
            limitedBy: album.endIndex
        ) else {
            return SearchStrategyInfo(strategy: .soundtrack, detectedPattern: pattern)
        }
        var movieName = String(album[album.startIndex ..< prefixEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Python rstrip "([-–—": trailing opener/dash characters fall off.
        while let last = movieName.last, "([-–—".contains(last) {
            movieName.removeLast()
        }
        movieName = movieName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !movieName.isEmpty {
            return SearchStrategyInfo(
                strategy: .soundtrack,
                detectedPattern: pattern,
                modifiedArtist: movieName,
                modifiedAlbum: movieName
            )
        }
    }
    return SearchStrategyInfo(strategy: .soundtrack, detectedPattern: pattern)
}

private func isVariousArtists(artist: String, names: [String]) -> Bool {
    let artistLower = artist.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    return names.contains { $0.lowercased() == artistLower }
}

private func unusualBracketStrip(album: String) -> String? {
    guard let match = album.range(of: #"\[([^\]]+)\]"#, options: .regularExpression) else {
        return nil
    }
    let content = String(album[match]).dropFirst().dropLast()
    let contentLower = content.lowercased()
    if normalBracketContent.contains(where: { contentLower.contains($0) }) {
        return nil
    }
    // Python str.isupper(): at least one CASED character, all cased ones
    // uppercase — caseless scripts (CJK, digits) never qualify.
    let isAllUppercase = content == content.uppercased() && content != content.lowercased()
    guard content.count > unusualBracketMinLength || isAllUppercase else {
        return nil
    }
    // Deliberate divergence: Python's re.sub("") glues surrounding words
    // together ("Sermon [X] Live" → "SermonLive"); joining with a space
    // keeps the query searchable.
    let stripped = album
        .replacingOccurrences(of: #"\s*\[[^\]]+\]\s*"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    // Python guards `if has_unusual and stripped` — a bracket-only album
    // must NOT retry with an empty query (Discogs would answer with the
    // artist's whole discography).
    return stripped.isEmpty ? nil : stripped
}
