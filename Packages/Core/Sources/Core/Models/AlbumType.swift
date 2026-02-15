// AlbumType.swift — Album classification for year handling strategy
// Ported from: album_type.py (405 LOC)
//
// Classifies albums as normal, special, compilation, or reissue
// based on pattern matching. Drives year update strategy selection.

import Foundation

// MARK: - Enums

/// Album type classification for year handling.
public enum AlbumType: String, Sendable, Codable, CaseIterable {
    case normal
    case special       // B-Sides, Demo, Vault, etc.
    case compilation   // Greatest Hits, Best Of, etc.
    case reissue       // Remastered, Anniversary, Deluxe, etc.
}

/// Strategy for handling year updates based on album type.
public enum YearHandlingStrategy: String, Sendable, Codable {
    case normal           // Apply year normally
    case markAndSkip      // Mark for verification, skip update
    case markAndUpdate    // Mark for verification, still update
}

// MARK: - AlbumTypeInfo

/// Result of album type detection.
public struct AlbumTypeInfo: Sendable {
    public let albumType: AlbumType
    public let detectedPattern: String?
    public let strategy: YearHandlingStrategy

    public init(
        albumType: AlbumType,
        detectedPattern: String?,
        strategy: YearHandlingStrategy
    ) {
        self.albumType = albumType
        self.detectedPattern = detectedPattern
        self.strategy = strategy
    }
}

// MARK: - Default Patterns

/// Patterns indicating special albums (B-Sides, Demo collections, etc.).
public let defaultSpecialPatterns: Set<String> = [
    "b-sides", "b-side", "d-sides", "d-side",
    "demo", "demos", "vault", "rarities", "rarity",
    "archive", "archives", "outtakes", "outtake",
    "unreleased", "sessions", "session",
    "bonus-tracks", "bonus", "extras",
    "bootleg", "bootlegs",
    "alternate", "alternates",
    "acoustic-versions", "live-sessions",
    "remixes", "remix",
]

/// Patterns indicating compilation albums.
public let defaultCompilationPatterns: Set<String> = [
    "greatest hits", "best of", "collection",
    "anthology", "compilation", "complete",
    "essential", "definitive", "ultimate",
    "gold", "platinum", "hits", "singles",
    "collected", "retrospective",
    "\u{0445}\u{0456}\u{0442}\u{0438}",  // Ukrainian: "hits"
    "\u{0445}\u{0456}\u{0442}",           // Ukrainian: "hit"
]

/// Patterns indicating reissued/remastered albums.
public let defaultReissuePatterns: Set<String> = [
    "remaster", "remastered", "anniversary",
    "deluxe", "expanded", "special edition",
    "collector", "redux", "revisited",
    "re-release", "re-issue", "reissue",
    "rerelease", "remanufacture",
    "re-record", "re-recorded",
]

// MARK: - Detection

/// Detect the type of album based on its name.
///
/// Analyzes album name for patterns indicating special handling is needed
/// for year updates. Checks special, compilation, then reissue patterns.
///
/// - Parameters:
///   - albumName: The album name to analyze
///   - specialPatterns: Override default special patterns
///   - compilationPatterns: Override default compilation patterns
///   - reissuePatterns: Override default reissue patterns
/// - Returns: Detection result with type, matched pattern, and handling strategy
public func detectAlbumType(
    _ albumName: String,
    specialPatterns: Set<String> = defaultSpecialPatterns,
    compilationPatterns: Set<String> = defaultCompilationPatterns,
    reissuePatterns: Set<String> = defaultReissuePatterns
) -> AlbumTypeInfo {
    guard !albumName.isEmpty else {
        return AlbumTypeInfo(albumType: .normal, detectedPattern: nil, strategy: .normal)
    }

    let normalized = normalizeForAlbumTypeMatching(albumName)

    if let pattern = findPatternMatch(in: normalized, patterns: specialPatterns) {
        return AlbumTypeInfo(
            albumType: .special, detectedPattern: pattern, strategy: .markAndSkip
        )
    }

    if let pattern = findPatternMatch(in: normalized, patterns: compilationPatterns) {
        return AlbumTypeInfo(
            albumType: .compilation, detectedPattern: pattern, strategy: .markAndSkip
        )
    }

    if let pattern = findPatternMatch(in: normalized, patterns: reissuePatterns) {
        return AlbumTypeInfo(
            albumType: .reissue, detectedPattern: pattern, strategy: .markAndUpdate
        )
    }

    return AlbumTypeInfo(albumType: .normal, detectedPattern: nil, strategy: .normal)
}

/// Check if album name indicates a special album type.
///
/// - Returns: Tuple of (isSpecial, detectedPattern)
public func isSpecialAlbum(_ albumName: String) -> (isSpecial: Bool, detectedPattern: String?) {
    let info = detectAlbumType(albumName)
    return (info.albumType != .normal, info.detectedPattern)
}

/// Get the year handling strategy for an album.
public func yearHandlingStrategy(for albumName: String) -> YearHandlingStrategy {
    detectAlbumType(albumName).strategy
}

// MARK: - Internal Helpers

/// Normalize album name for pattern matching: lowercase, replace hyphens/underscores
/// with spaces, remove bracket characters, collapse whitespace.
private func normalizeForAlbumTypeMatching(_ text: String) -> String {
    var result = text.lowercased()
    result = result.replacingOccurrences(of: "-", with: " ")
    result = result.replacingOccurrences(of: "_", with: " ")
    for bracket in ["(", ")", "[", "]", "{", "}"] {
        result = result.replacingOccurrences(of: bracket, with: " ")
    }
    return result.split(separator: " ").joined(separator: " ")
}

/// Find first matching pattern in text using word boundary matching.
private func findPatternMatch(in normalizedText: String, patterns: Set<String>) -> String? {
    for pattern in patterns {
        let normalizedPattern = pattern
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")

        let escaped = NSRegularExpression.escapedPattern(for: normalizedPattern)
        guard let regex = try? NSRegularExpression(
            pattern: "\\b\(escaped)\\b",
            options: .caseInsensitive
        ) else { continue }

        let range = NSRange(normalizedText.startIndex..., in: normalizedText)
        if regex.firstMatch(in: normalizedText, range: range) != nil {
            return pattern
        }
    }
    return nil
}
