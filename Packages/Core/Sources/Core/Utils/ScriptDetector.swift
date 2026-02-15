// ScriptDetector.swift — Unicode script detection for text analysis
// Ported from: script_detection.py (519 LOC)
//
// Detects dominant writing script in text for matching strategy selection.
// Uses Unicode scalar ranges (not Character ranges) for correct detection.

import Foundation

// MARK: - ScriptType

/// Writing script classifications used for matching strategy selection.
public enum ScriptType: String, Sendable, CaseIterable, Codable {
    case arabic
    case chinese
    case cyrillic
    case devanagari
    case greek
    case hebrew
    case japanese
    case korean
    case latin
    case thai
    case mixed
    case unknown
}

// MARK: - Constants

/// Minimum ratio for a script to be considered significant in mixed-script text.
private let minimumScriptRatio: Double = 0.25

// MARK: - Individual Script Detectors

/// Check if text contains Arabic characters (U+0600–U+06FF, U+0750–U+077F).
public func hasArabic(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
        (0x0600 ... 0x06FF).contains(scalar.value)
            || (0x0750 ... 0x077F).contains(scalar.value)
    }
}

/// Check if text contains Chinese characters (CJK Unified Ideographs + Extension A).
public func hasChinese(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
        (0x4E00 ... 0x9FFF).contains(scalar.value)
            || (0x3400 ... 0x4DBF).contains(scalar.value)
    }
}

/// Check if text contains Cyrillic characters.
public func hasCyrillic(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
        (0x0400 ... 0x04FF).contains(scalar.value)
            || (0x0500 ... 0x052F).contains(scalar.value)
            || (0x2DE0 ... 0x2DFF).contains(scalar.value)
            || (0xA640 ... 0xA69F).contains(scalar.value)
    }
}

/// Check if text contains Devanagari characters (U+0900–U+097F).
public func hasDevanagari(_ text: String) -> Bool {
    text.unicodeScalars.contains { (0x0900 ... 0x097F).contains($0.value) }
}

/// Check if text contains Greek characters (U+0370–U+03FF).
public func hasGreek(_ text: String) -> Bool {
    text.unicodeScalars.contains { (0x0370 ... 0x03FF).contains($0.value) }
}

/// Check if text contains Hebrew characters (U+0590–U+05FF).
public func hasHebrew(_ text: String) -> Bool {
    text.unicodeScalars.contains { (0x0590 ... 0x05FF).contains($0.value) }
}

/// Check if text contains Japanese-specific characters (Hiragana + Katakana).
///
/// Note: Kanji (CJK Unified Ideographs) are shared with Chinese.
/// Use `hasHiraganaOrKatakana` to distinguish Japanese from Chinese.
public func hasJapanese(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
        (0x3040 ... 0x309F).contains(scalar.value) // Hiragana
            || (0x30A0 ... 0x30FF).contains(scalar.value) // Katakana
            || (0x4E00 ... 0x9FFF).contains(scalar.value) // CJK (Kanji)
    }
}

/// Check if text contains Korean characters (Hangul Syllables + Jamo).
public func hasKorean(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
        (0xAC00 ... 0xD7AF).contains(scalar.value)
            || (0x1100 ... 0x11FF).contains(scalar.value)
    }
}

/// Check if text contains Latin alphabetic characters (Basic + Extended).
public func hasLatin(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
        let value = scalar.value
        guard scalar.properties.isAlphabetic else { return false }
        return (0x0041 ... 0x005A).contains(value) // A-Z
            || (0x0061 ... 0x007A).contains(value) // a-z
            || (0x0080 ... 0x00FF).contains(value) // Latin-1 Supplement
            || (0x0100 ... 0x017F).contains(value) // Latin Extended-A
            || (0x0180 ... 0x024F).contains(value) // Latin Extended-B
    }
}

/// Check if text contains Thai characters (U+0E00–U+0E7F).
public func hasThai(_ text: String) -> Bool {
    text.unicodeScalars.contains { (0x0E00 ... 0x0E7F).contains($0.value) }
}

// MARK: - CJK Convenience

/// Check if text contains any CJK characters (Chinese, Japanese, or Korean).
public func isCJK(_ text: String) -> Bool {
    hasChinese(text) || hasJapanese(text) || hasKorean(text)
}

/// Check if text contains Latin alphabetic characters.
public func isLatin(_ text: String) -> Bool {
    hasLatin(text)
}

// MARK: - Script Detection

/// Detect the primary (dominant) script used in text.
///
/// Uses character counting to determine dominance when multiple scripts are present.
/// Special handling for CJK disambiguation (Japanese vs Chinese via hiragana/katakana).
///
/// - Parameter text: Text to analyze
/// - Returns: Primary script type
public func dominantScript(of text: String) -> ScriptType {
    guard !text.isEmpty else { return .unknown }

    // Special handling for CJK scripts
    if let cjkResult = handleCJKDetection(text) {
        return cjkResult
    }

    // Count characters by script type
    let (scriptCounts, totalChars) = countScriptCharacters(text)

    guard totalChars > 0, !scriptCounts.isEmpty else { return .unknown }

    // Special case: Latin + one other script
    if scriptCounts.count == 2, scriptCounts[.latin] != nil {
        if let result = handleLatinMixedCase(scriptCounts, totalChars: totalChars) {
            return result
        }
    }

    // Find the script with the most characters
    let maxCount = scriptCounts.values.max() ?? 0
    let dominantScripts = scriptCounts.filter { $0.value == maxCount }.map(\.key)

    return dominantScripts.count == 1 ? dominantScripts[0] : .mixed
}

/// Get all scripts detected in text.
///
/// - Parameter text: Text to analyze
/// - Returns: List of detected script types (excluding .mixed and .unknown)
public func getAllScripts(_ text: String) -> [ScriptType] {
    guard !text.isEmpty else { return [] }

    let detectors: [(ScriptType, (String) -> Bool)] = [
        (.arabic, hasArabic),
        (.chinese, hasChinese),
        (.cyrillic, hasCyrillic),
        (.devanagari, hasDevanagari),
        (.greek, hasGreek),
        (.hebrew, hasHebrew),
        (.japanese, hasJapanese),
        (.korean, hasKorean),
        (.latin, hasLatin),
        (.thai, hasThai),
    ]

    return detectors.compactMap { scriptType, detector in
        detector(text) ? scriptType : nil
    }
}

/// Check if text is primarily in Cyrillic script.
///
/// Returns `true` when dominant script is Cyrillic, or mixed with Cyrillic present.
public func isPrimarilyCyrillic(_ text: String) -> Bool {
    let script = dominantScript(of: text)
    return (script == .cyrillic || script == .mixed) && hasCyrillic(text)
}

// MARK: - Internal Helpers

private func scriptDetectorPairs() -> [(ScriptType, (String) -> Bool)] {
    [
        (.arabic, hasArabic),
        (.chinese, hasChinese),
        (.cyrillic, hasCyrillic),
        (.devanagari, hasDevanagari),
        (.greek, hasGreek),
        (.hebrew, hasHebrew),
        (.japanese, hasJapanese),
        (.korean, hasKorean),
        (.latin, hasLatin),
        (.thai, hasThai),
    ]
}

private func handleCJKDetection(_ text: String) -> ScriptType? {
    guard hasJapanese(text), hasChinese(text) else { return nil }

    // Hiragana or Katakana are unique to Japanese
    let hasKana = text.unicodeScalars.contains { scalar in
        (0x3040 ... 0x309F).contains(scalar.value) || (0x30A0 ... 0x30FF).contains(scalar.value)
    }

    // If only Kanji (shared), default to Chinese as it's more common
    return hasKana ? .japanese : .chinese
}

private func countScriptCharacters(_ text: String) -> ([ScriptType: Int], Int) {
    var scriptCounts: [ScriptType: Int] = [:]
    var totalChars = 0

    for scalar in text.unicodeScalars {
        guard scalar.properties.isAlphabetic else { continue }

        totalChars += 1
        let charString = String(scalar)

        for (scriptType, detector) in scriptDetectorPairs() where detector(charString) {
            scriptCounts[scriptType, default: 0] += 1
            break // Count character only for the first matching script
        }
    }

    return (scriptCounts, totalChars)
}

private func handleLatinMixedCase(
    _ scriptCounts: [ScriptType: Int],
    totalChars: Int
) -> ScriptType? {
    guard scriptCounts.count == 2, let latinCount = scriptCounts[.latin] else { return nil }

    guard let nonLatin = scriptCounts.first(where: { $0.key != .latin }) else { return nil }
    let latinRatio = Double(latinCount) / Double(totalChars)
    let nonLatinRatio = Double(nonLatin.value) / Double(totalChars)

    if latinRatio < minimumScriptRatio {
        return nonLatin.key
    }
    if nonLatinRatio < minimumScriptRatio {
        return .latin
    }
    return .mixed
}
