import Foundation

/// How to FIND a year in the first place (query rewriting), as opposed to
/// AlbumType's how-to-HANDLE-a-year-once-found. Verbatim port of Python's
/// search_strategy.py: detection order soundtrack → Various Artists →
/// unusual brackets → normal, first match wins, and the rewrite only ever
/// runs as a second-chance search after an empty standard aggregate.
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

private let defaultSoundtrackPatterns = [
    "soundtrack",
    "original score",
    "OST",
    "motion picture",
    "film score",
]

private let defaultVariousArtistsNames = [
    "Various Artists",
    "Various",
    "VA",
    "Різні виконавці",
]

/// Short tags like [CD1] are normal; longer content like
/// [MESSAGE FROM THE CLERGY] is unusual (Python threshold).
private let unusualBracketMinLength = 10

private let normalBracketContent = ["deluxe", "remaster", "bonus", "disc", "cd", "version"]

public func detectSearchStrategy(
    artist: String,
    album: String,
    soundtrackPatterns: [String],
    variousArtistsNames: [String]
) -> SearchStrategyInfo {
    guard !album.isEmpty else {
        return SearchStrategyInfo(strategy: .normal)
    }

    let soundtrack = soundtrackPatterns.isEmpty ? defaultSoundtrackPatterns : soundtrackPatterns
    let various = variousArtistsNames.isEmpty ? defaultVariousArtistsNames : variousArtistsNames

    if let info = soundtrackStrategy(album: album, patterns: soundtrack) {
        return info
    }
    if isVariousArtists(artist: artist, names: various) {
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
        let prefixEnd = album.index(album.startIndex, offsetBy: albumLower.distance(
            from: albumLower.startIndex,
            to: range.lowerBound
        ))
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
    let isAllUppercase = content == content.uppercased() && content.rangeOfCharacter(from: .letters) != nil
    guard content.count > unusualBracketMinLength || isAllUppercase else {
        return nil
    }
    return album
        .replacingOccurrences(of: #"\s*\[[^\]]+\]\s*"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
