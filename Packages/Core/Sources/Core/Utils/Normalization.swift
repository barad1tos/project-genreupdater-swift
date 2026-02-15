// Normalization.swift — Unified text normalization for artist/album matching
// Ported from: normalization.py (51 LOC)
//
// Single source of truth for normalizing artist and album names
// when used for matching, comparison, or as dictionary/cache keys.

import Foundation

// MARK: - Public API

/// Normalize text for case-insensitive matching and cache keys.
///
/// This is THE standard normalization for all artist/album comparisons.
/// Use this everywhere you need to:
/// - Compare artist/album names for equality
/// - Generate cache keys
/// - Group tracks by artist
/// - Look up values in mapping dictionaries
///
/// - Parameter text: Text to normalize (artist name, album name, etc.)
/// - Returns: Normalized text: stripped whitespace, lowercased
public func normalizeForMatching(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    return trimmed.lowercased()
}

/// Check if two names are equivalent after normalization.
///
/// - Parameters:
///   - name1: First name to compare
///   - name2: Second name to compare
/// - Returns: `true` if names are equivalent after normalization
public func areNamesEqual(_ name1: String, _ name2: String) -> Bool {
    normalizeForMatching(name1) == normalizeForMatching(name2)
}
