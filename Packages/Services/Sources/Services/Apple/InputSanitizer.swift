// InputSanitizer.swift — AppleScript security sanitizer
// Ported from: src/services/apple/sanitizer.py (202 LOC) + file_validator.py (141 LOC)
//
// Defense-in-depth for AppleScript injection prevention:
// 1. String escaping (backslashes, quotes)
// 2. Dangerous pattern detection (shell scripts, system events)
// 3. Script size limits (DoS prevention)
//
// In the Swift app, NSUserAppleScriptTask provides additional sandboxing,
// but input sanitization remains critical for the arguments we pass to scripts.

import Core
import Foundation
import OSLog

private let log = AppLogger.make(category: "sanitizer")

// MARK: - Errors

/// Error thrown when input fails security validation.
public enum SanitizationError: Error, LocalizedError {
    case dangerousPattern(pattern: String, input: String)
    case inputTooLarge(size: Int, maxSize: Int)
    case emptyInput
    case invalidCharacters(detail: String)

    public var errorDescription: String? {
        switch self {
        case let .dangerousPattern(pattern, _):
            "Dangerous AppleScript pattern detected: '\(pattern)'"
        case let .inputTooLarge(size, maxSize):
            "Input too large: \(size) characters (max \(maxSize))"
        case .emptyInput:
            "Input must not be empty"
        case let .invalidCharacters(detail):
            "Invalid characters in input: \(detail)"
        }
    }
}

// MARK: - Input Sanitizer

/// Security-focused input sanitizer for AppleScript arguments.
///
/// All strings passed to AppleScript must go through this sanitizer
/// to prevent injection attacks. The sanitizer is intentionally strict —
/// it's better to reject valid input than to allow dangerous input.
public enum InputSanitizer {
    /// Maximum allowed size for any input string (10 KB).
    public static let maxInputSize = 10_000

    /// Regex patterns that indicate dangerous AppleScript commands.
    private static let dangerousPatterns: [NSRegularExpression] = {
        let patterns = [
            #"do\s+shell\s+script"#,
            #"tell\s+application\s+"Finder""#,
            #"tell\s+application\s+"System\s+Events""#,
            #"load\s+script"#,
            #"store\s+script"#,
            #"choose\s+file"#,
            #"choose\s+folder"#,
            #"open\s+location"#,
            #"keystroke|key\s+code"#,
            #"system\s+attribute"#,
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    /// Sanitize a string for safe use as an AppleScript argument.
    public static func sanitizeString(_ value: String) throws -> String {
        guard !value.isEmpty else {
            throw SanitizationError.emptyInput
        }

        guard value.count <= maxInputSize else {
            throw SanitizationError.inputTooLarge(size: value.count, maxSize: maxInputSize)
        }

        // Escape backslashes first (before adding new ones), then quotes
        var sanitized = value.replacingOccurrences(of: "\\", with: "\\\\")
        sanitized = sanitized.replacingOccurrences(of: "\"", with: "\\\"")

        if value != sanitized {
            log.debug("Sanitized AppleScript string: \(value.count, privacy: .public) chars, changes made")
        }

        return sanitized
    }

    /// Sanitize AppleScript **code fragments** by stripping shell metacharacters.
    ///
    /// Use this ONLY for dynamically composed script code (e.g., property names,
    /// script identifiers). **Never** use this for track data (artist names, album
    /// titles) — those characters are valid in track metadata.
    ///
    /// For user-supplied data values (track names, artist names), use
    /// ``escapeStringValue(_:)`` instead, which preserves all characters but
    /// escapes quotes and backslashes for safe embedding in AppleScript strings.
    public static func sanitizeScriptCode(_ value: String) -> String {
        var result = value
        for char in [";", "|", "&", "`", "$", "(", ")", "{", "}"] {
            result = result.replacingOccurrences(of: char, with: "")
        }
        return result
    }

    /// Escape a **data value** (track name, artist name, album title) for safe
    /// embedding inside an AppleScript quoted string.
    ///
    /// This escapes `"` and `\` so the value can be safely interpolated into
    /// AppleScript like: `"set trackName to \"" & escapedValue & "\""`.
    /// Unlike ``sanitizeScriptCode(_:)``, this preserves parentheses, brackets,
    /// and all other characters that are valid in track metadata.
    ///
    /// - Parameter value: Raw track metadata string
    /// - Returns: Escaped string safe for AppleScript string interpolation
    public static func escapeStringValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Validate that a string doesn't contain dangerous AppleScript patterns.
    public static func validateScriptCode(_ code: String) throws {
        guard !code.isEmpty else {
            throw SanitizationError.emptyInput
        }

        guard code.count <= maxInputSize else {
            throw SanitizationError.inputTooLarge(size: code.count, maxSize: maxInputSize)
        }

        let range = NSRange(code.startIndex..., in: code)
        for pattern in dangerousPatterns {
            if let match = pattern.firstMatch(in: code, range: range) {
                guard let matchedRange = Range(match.range, in: code) else { continue }
                let matchedText = String(code[matchedRange])
                log.error("Security violation: dangerous pattern '\(matchedText, privacy: .public)' in script")
                throw SanitizationError.dangerousPattern(pattern: matchedText, input: String(code.prefix(100)))
            }
        }

        log.debug("Script code passed security validation: \(code.count, privacy: .public) characters")
    }

    /// Sanitize an array of arguments for AppleScript execution.
    public static func sanitizeArguments(_ arguments: [String]) throws -> [String] {
        try arguments.map { try sanitizeString($0) }
    }

    /// Validate a file path for safe use (no traversal attacks, valid extension).
    public static func validateFilePath(_ path: String, allowedExtensions: Set<String>) throws -> URL {
        guard !path.isEmpty else {
            throw SanitizationError.emptyInput
        }

        let url = URL(filePath: path).standardized

        // Check for directory traversal
        if path.contains("..") {
            throw SanitizationError.invalidCharacters(detail: "Path traversal (..) not allowed")
        }

        // Check extension
        let ext = url.pathExtension.lowercased()
        let allowedExts = allowedExtensions.map { $0.lowercased().replacingOccurrences(of: ".", with: "") }
        guard allowedExts.contains(ext) else {
            throw SanitizationError.invalidCharacters(
                detail: "Extension '.\(ext)' not in allowed list: \(allowedExtensions.joined(separator: ", "))"
            )
        }

        return url
    }
}
