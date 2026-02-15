// AlbumMatcher.swift — Fuzzy album matching with variant detection
// Ported from: album matching logic in metadata_utils.py
//
// Provides Levenshtein distance, fuzzy matching, and album variant
// detection (remaster, deluxe, disc number handling).

import Foundation

// MARK: - Levenshtein Distance

/// Compute the Levenshtein (edit) distance between two strings.
///
/// Uses the standard O(nm) dynamic programming algorithm.
/// Suitable for strings < 200 characters (typical album/artist names).
///
/// - Returns: Minimum number of single-character edits to transform s1 into s2
public func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
    let len1 = s1.count
    let len2 = s2.count

    if len1 == 0 { return len2 }
    if len2 == 0 { return len1 }

    let s1Chars = Array(s1)
    let s2Chars = Array(s2)

    var prev = Array(0...len2)
    var curr = Array(repeating: 0, count: len2 + 1)

    for row in 1...len1 {
        curr[0] = row
        for col in 1...len2 {
            let cost = s1Chars[row - 1] == s2Chars[col - 1] ? 0 : 1
            curr[col] = min(
                prev[col] + 1,       // deletion
                curr[col - 1] + 1,   // insertion
                prev[col - 1] + cost  // substitution
            )
        }
        swap(&prev, &curr)
    }

    return prev[len2]
}

// MARK: - Normalized Similarity

/// Compute normalized similarity between two strings (0.0 to 1.0).
///
/// Returns 1.0 for identical strings, 0.0 for completely different.
/// Based on Levenshtein distance normalized by the longer string length.
public func normalizedSimilarity(_ s1: String, _ s2: String) -> Double {
    let maxLen = max(s1.count, s2.count)
    guard maxLen > 0 else { return 1.0 }
    let distance = levenshteinDistance(s1, s2)
    return 1.0 - Double(distance) / Double(maxLen)
}

// MARK: - Fuzzy Album Matching

/// Check if two album names match with fuzzy threshold.
///
/// Normalizes both names before comparison.
///
/// - Parameters:
///   - album1: First album name
///   - album2: Second album name
///   - threshold: Minimum similarity score (0.0 to 1.0, default 0.85)
/// - Returns: `true` if similarity >= threshold
public func fuzzyAlbumMatch(_ album1: String, _ album2: String, threshold: Double = 0.85) -> Bool {
    let norm1 = normalizeForMatching(album1)
    let norm2 = normalizeForMatching(album2)

    // Exact match after normalization
    if norm1 == norm2 { return true }

    return normalizedSimilarity(norm1, norm2) >= threshold
}

// MARK: - Album Variant Detection

/// Check if two album names are variants of the same release.
///
/// Strips remaster/deluxe/edition markers and disc numbers before comparison.
/// Useful for matching "Album (Remastered)" with "Album" or "Album (Deluxe)".
///
/// - Parameters:
///   - album1: First album name
///   - album2: Second album name
///   - threshold: Minimum similarity after cleaning (default 0.85)
/// - Returns: `true` if the cleaned names match above threshold
public func isAlbumVariant(_ album1: String, _ album2: String, threshold: Double = 0.85) -> Bool {
    let cleaned1 = normalizeAlbumForComparison(album1)
    let cleaned2 = normalizeAlbumForComparison(album2)

    if cleaned1 == cleaned2 { return true }

    return normalizedSimilarity(cleaned1, cleaned2) >= threshold
}

// MARK: - Disc Number Handling

/// Remove disc/CD number suffixes from album name.
///
/// Handles patterns: "Disc 1", "Disc1", "CD 2", "CD2", "Disk 1"
///
/// - Parameter albumName: Album name to clean
/// - Returns: Album name with disc number removed
public func stripDiscNumber(_ albumName: String) -> String {
    guard let regex = try? NSRegularExpression(
        pattern: "[\\s\\-]*(?:disc|disk|cd)\\s*\\d+\\s*$",
        options: .caseInsensitive
    ) else { return albumName }

    let range = NSRange(albumName.startIndex..., in: albumName)
    let result = regex.stringByReplacingMatches(
        in: albumName, range: range, withTemplate: ""
    )
    return result.trimmingCharacters(in: .whitespaces)
}

// MARK: - Album Comparison Normalization

/// Normalize album name for comparison: strip disc numbers, remove
/// remaster/deluxe markers, then apply standard normalization.
///
/// - Parameter album: Album name to normalize
/// - Returns: Cleaned, lowercased album name for comparison
public func normalizeAlbumForComparison(_ album: String) -> String {
    var cleaned = album

    // Strip disc numbers
    cleaned = stripDiscNumber(cleaned)

    // Remove common remaster/deluxe markers in parentheses and brackets
    cleaned = removeParenthesesWithKeywords(cleaned, keywords: [
        "remaster", "remastered", "deluxe", "expanded",
        "anniversary", "special edition", "bonus",
        "collector", "redux",
    ])

    return normalizeForMatching(cleaned)
}
