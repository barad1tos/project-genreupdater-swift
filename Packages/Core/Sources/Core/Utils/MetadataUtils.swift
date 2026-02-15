// MetadataUtils.swift — Metadata cleaning functions for artist/album names
// Ported from: metadata_utils.py (803 LOC — cleaning functions only)
//
// Removes remaster tags, edition markers, and configured suffixes from
// track and album names. Uses balanced parentheses/bracket parsing.

import Foundation

// MARK: - Remaster Detection

/// Check if text contains remaster-related keywords.
///
/// - Parameters:
///   - text: Text to check
///   - keywords: Keywords to search for (defaults to common remaster terms)
/// - Returns: `true` if any keyword is found (case-insensitive)
public func isRemaster(_ text: String, keywords: [String]? = nil) -> Bool { // swiftlint:disable:this inclusive_language
    let kws = keywords ?? ["remaster", "remastered"]
    let lower = text.lowercased()
    return kws.contains { lower.contains($0.lowercased()) }
}

// MARK: - Parentheses/Bracket Removal

/// Remove parenthetical and bracket segments containing any of the keywords.
///
/// Handles balanced parentheses (including nesting) and square brackets.
/// Case-insensitive keyword matching.
///
/// - Parameters:
///   - name: The string to process
///   - keywords: Keywords to search for in segments
/// - Returns: Cleaned string with matching segments removed, whitespace collapsed
public func removeParenthesesWithKeywords(_ name: String, keywords: [String]) -> String {
    guard !name.isEmpty, !keywords.isEmpty else { return name }

    var cleaned = name
    cleaned = removeSegments(from: cleaned, open: "(", close: ")", balanced: true, keywords: keywords)
    cleaned = removeSegments(from: cleaned, open: "[", close: "]", balanced: false, keywords: keywords)
    return cleaned.split(separator: " ").joined(separator: " ")
}

// MARK: - Album Suffix Removal

/// Remove configured suffix patterns from album title.
///
/// Iteratively removes matching suffixes until no more matches are found.
/// Suffixes are sorted by length (longest first) for greedy matching.
///
/// - Parameters:
///   - album: Album title to clean
///   - suffixes: List of suffix strings to remove
/// - Returns: Cleaned album title
public func stripAlbumSuffixes(_ album: String, suffixes: [String]) -> String {
    guard !suffixes.isEmpty else { return album }

    let compiled = compileSuffixPatterns(suffixes)
    guard !compiled.isEmpty else { return album }

    var cleaned = album

    while true {
        var matched = false
        for (_, pattern) in compiled {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            guard let match = pattern.firstMatch(in: cleaned, range: range),
                  let matchRange = Range(match.range, in: cleaned)
            else { continue }

            cleaned = String(cleaned[cleaned.startIndex ..< matchRange.lowerBound])
            cleaned = cleaned.trimmingCharacters(
                in: CharacterSet(charactersIn: " \t-\u{2013}\u{2014}")
            )
            matched = true
            break
        }
        if !matched { break }
    }

    return cleaned
}

// MARK: - Clean Names Pipeline

/// Clean track and album names per configuration: remove remaster segments and suffixes.
///
/// Skips artist+album pairs in the exceptions list.
///
/// - Parameters:
///   - artist: Artist name (used for exception checking)
///   - trackName: Raw track title to clean
///   - albumName: Raw album title to clean
///   - config: Cleaning configuration with keywords and suffixes
/// - Returns: Tuple of (cleanedTrack, cleanedAlbum)
public func cleanNames(
    artist: String,
    trackName: String,
    albumName: String,
    config: CleaningConfig
) -> (cleanedTrack: String, cleanedAlbum: String) {
    // Check exceptions
    if isCleaningException(
        artist: artist,
        album: albumName,
        exceptions: config.trackCleaningExceptions
    ) {
        return (
            trackName.trimmingCharacters(in: .whitespaces),
            albumName.trimmingCharacters(in: .whitespaces)
        )
    }

    let keywords = config.remasterKeywords

    // Remove parenthetical segments containing remaster keywords
    var cleanedTrack = removeParenthesesWithKeywords(trackName, keywords: keywords)
    var cleanedAlbum = removeParenthesesWithKeywords(albumName, keywords: keywords)

    // Collapse whitespace
    cleanedTrack = collapseWhitespace(cleanedTrack)
    cleanedAlbum = collapseWhitespace(cleanedAlbum)

    // Strip configured album suffixes
    cleanedAlbum = stripAlbumSuffixes(cleanedAlbum, suffixes: config.albumSuffixesToRemove)

    return (cleanedTrack, cleanedAlbum)
}

// MARK: - Internal Helpers

/// Remove segments delimited by open/close characters that contain keywords.
private func removeSegments(
    from text: String,
    open: Character,
    close: Character,
    balanced: Bool,
    keywords: [String]
) -> String {
    var chars = Array(text)
    var position = 0

    while position < chars.count {
        if chars[position] == open {
            let endPos: Int = if balanced {
                findMatchingParenthesis(chars, start: position, open: open, close: close)
            } else {
                findClosingBracket(chars, start: position, close: close)
            }

            if endPos != -1 {
                let segment = String(chars[position ... endPos])
                if textContainsKeywords(segment, keywords: keywords) {
                    chars.removeSubrange(position ... endPos)
                    continue
                }
            }
        }
        position += 1
    }

    return String(chars)
}

/// Find matching closing character with balanced nesting.
private func findMatchingParenthesis(
    _ chars: [Character],
    start: Int,
    open: Character,
    close: Character
) -> Int {
    var count = 1
    var position = start + 1
    while position < chars.count, count > 0 {
        if chars[position] == open {
            count += 1
        } else if chars[position] == close {
            count -= 1
        }
        position += 1
    }
    return count == 0 ? position - 1 : -1
}

/// Find the next occurrence of the closing character after start.
private func findClosingBracket(_ chars: [Character], start: Int, close: Character) -> Int {
    for idx in (start + 1) ..< chars.count where chars[idx] == close {
        return idx
    }
    return -1
}

/// Check if text contains any of the keywords (case-insensitive).
private func textContainsKeywords(_ text: String, keywords: [String]) -> Bool {
    let lower = text.lowercased()
    return keywords.contains { lower.contains($0.lowercased()) }
}

/// Compile configured album suffixes into regex patterns sorted by length (longest first).
private func compileSuffixPatterns(_ rawSuffixes: [String]) -> [(String, NSRegularExpression)] {
    // Deduplicate preserving order
    var seen = Set<String>()
    var deduped: [String] = []
    for suffix in rawSuffixes where seen.insert(suffix).inserted {
        deduped.append(suffix)
    }
    deduped.sort { $0.count > $1.count }

    var result: [(String, NSRegularExpression)] = []
    for suffix in deduped {
        let trimmed = suffix.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }

        let specialChars = CharacterSet(charactersIn: " ()\u{2013}\u{2014}-")
        let hasSpecial = suffix.unicodeScalars.contains { specialChars.contains($0) }

        let pattern: String
        if hasSpecial {
            // Match literally at end of string (rstrip trailing whitespace from suffix)
            var rstripped = suffix
            while rstripped.last?.isWhitespace == true {
                rstripped.removeLast()
            }
            let escaped = NSRegularExpression.escapedPattern(for: rstripped)
            pattern = "\(escaped)\\s*$"
        } else {
            // Word boundary match at end of string
            let escaped = NSRegularExpression.escapedPattern(for: trimmed)
            pattern = "[ \\t\\x{2013}\\x{2014}\\-]*\\b\(escaped)\\b\\s*$"
        }

        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            result.append((suffix, regex))
        }
    }

    return result
}

/// Check if artist/album pair is in the cleaning exceptions list.
private func isCleaningException(
    artist: String,
    album: String,
    exceptions: [TrackCleaningException]
) -> Bool {
    let artistLower = artist.lowercased()
    let albumLower = album.lowercased()
    return exceptions.contains {
        $0.artist.lowercased() == artistLower && $0.album.lowercased() == albumLower
    }
}

/// Collapse multiple whitespace characters into single spaces and trim.
private func collapseWhitespace(_ text: String) -> String {
    text.split(separator: " ").joined(separator: " ")
        .trimmingCharacters(in: .whitespaces)
}
