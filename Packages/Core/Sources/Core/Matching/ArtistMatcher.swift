// ArtistMatcher.swift — Artist name normalization and matching
// Ported from: year_utils.py (normalize_collaboration_artist)
//              + artist matching logic from metadata_utils.py
//
// Handles collaboration splitting, "The" prefix removal,
// featured artist extraction, and CJK-aware matching.

import Foundation

// MARK: - Collaboration Separators

/// Ordered list of collaboration separators, checked in priority order.
///
/// Longer/more specific separators first to avoid greedy splits.
/// For example " feat. " should be checked before " ft. ".
private let collaborationSeparators: [String] = [
    " feat. ",
    " feat ",
    " ft. ",
    " ft ",
    " vs. ",
    " vs ",
    " with ",
    " and ",
    " & ",
    " x ",
    " X ",
]

// MARK: - Main Artist Extraction

/// Extract the main (primary) artist from a collaboration string.
///
/// For collaborations like "Drake feat. Rihanna" or "Daft Punk & Pharrell",
/// returns the first artist name. Used for grouping tracks by primary artist.
///
/// - Parameter artist: Artist name potentially containing collaborations
/// - Returns: Primary artist name, trimmed
public func extractMainArtist(_ artist: String) -> String {
    let trimmed = artist.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return "" }

    for separator in collaborationSeparators {
        // Case-insensitive search for separator
        if let range = trimmed.range(
            of: separator,
            options: .caseInsensitive
        ) {
            let main = trimmed[trimmed.startIndex ..< range.lowerBound]
            let result = main.trimmingCharacters(in: .whitespaces)
            return result.isEmpty ? trimmed : result
        }
    }

    return trimmed
}

// MARK: - Collaboration Split

/// Split a collaboration string into individual artist names.
///
/// For "A & B feat. C" returns ["A", "B", "C"].
/// Splits on ALL collaboration separators recursively.
///
/// - Parameter artist: Artist name with potential collaborations
/// - Returns: Array of individual artist names, trimmed and non-empty
public func splitCollaborators(_ artist: String) -> [String] {
    let trimmed = artist.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return [] }

    var parts = [trimmed]

    for separator in collaborationSeparators {
        var newParts: [String] = []
        for part in parts {
            let splits = part.splitCaseInsensitive(separator: separator)
            newParts.append(contentsOf: splits)
        }
        parts = newParts
    }

    return parts
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

// MARK: - "The" Prefix Normalization

/// Remove leading "The " from artist name for matching.
///
/// Handles common variations: "The Beatles" → "Beatles",
/// "THE WHO" → "WHO". Case-insensitive.
///
/// - Parameter artist: Artist name to normalize
/// - Returns: Name with "The " prefix removed if present
public func stripThePrefix(_ artist: String) -> String {
    let trimmed = artist.trimmingCharacters(in: .whitespaces)
    guard trimmed.count > 4 else { return trimmed }

    let prefix = trimmed.prefix(4).lowercased()
    if prefix == "the " {
        let rest = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? trimmed : rest
    }

    return trimmed
}

// MARK: - Featured Artist Extraction

/// Extract featured artists from a track or artist name.
///
/// Looks for "(feat. X)", "(ft. X)", "[feat. X]" patterns
/// in parentheses or brackets.
///
/// - Parameter text: Text containing potential featured artist info
/// - Returns: Array of featured artist names, or empty if none found
public func extractFeaturedArtists(_ text: String) -> [String] {
    guard let regex = try? NSRegularExpression(
        pattern: "[\\(\\[]\\s*(?:feat\\.?|ft\\.?|featuring)\\s+(.+?)[\\)\\]]",
        options: .caseInsensitive
    ) else { return [] }

    let range = NSRange(text.startIndex..., in: text)
    let matches = regex.matches(in: text, range: range)

    var artists: [String] = []
    for match in matches {
        guard match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text)
        else { continue }

        let captured = String(text[captureRange])
        // Split featured artists on commas and "&"
        let parts = captured
            .replacingOccurrences(of: " & ", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        artists.append(contentsOf: parts)
    }

    return artists
}

// MARK: - Artist Normalization for Matching

/// Normalize an artist name for comparison:
/// strip "The" prefix, extract main artist, lowercase.
///
/// - Parameter artist: Artist name to normalize
/// - Returns: Normalized artist string for comparison
public func normalizeArtistForMatching(_ artist: String) -> String {
    var name = extractMainArtist(artist)
    name = stripThePrefix(name)
    return normalizeForMatching(name)
}

// MARK: - Fuzzy Artist Match

/// Check if two artist names match with fuzzy threshold.
///
/// Applies artist-specific normalization before comparison.
/// CJK artists use exact match (fuzzy matching less reliable).
///
/// - Parameters:
///   - artist1: First artist name
///   - artist2: Second artist name
///   - threshold: Minimum similarity score (default 0.85)
/// - Returns: `true` if artists match above threshold
public func fuzzyArtistMatch(
    _ artist1: String,
    _ artist2: String,
    threshold: Double = 0.85
) -> Bool {
    let norm1 = normalizeArtistForMatching(artist1)
    let norm2 = normalizeArtistForMatching(artist2)

    // Exact match after normalization
    if norm1 == norm2 { return true }

    // CJK artists: use exact match only (fuzzy less reliable for ideographic scripts)
    if isCJK(norm1) || isCJK(norm2) {
        return norm1 == norm2
    }

    return normalizedSimilarity(norm1, norm2) >= threshold
}

// MARK: - Internal Helpers

extension String {
    /// Split string on separator case-insensitively.
    fileprivate func splitCaseInsensitive(separator: String) -> [String] {
        var results: [String] = []
        var remaining = self[startIndex...]

        while let range = remaining.range(of: separator, options: .caseInsensitive) {
            let part = remaining[remaining.startIndex ..< range.lowerBound]
            results.append(String(part))
            remaining = remaining[range.upperBound...]
        }

        results.append(String(remaining))
        return results
    }
}
