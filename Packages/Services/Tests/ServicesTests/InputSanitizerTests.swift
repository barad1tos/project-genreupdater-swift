import Foundation
import Testing
@testable import Services

// MARK: - sanitizeString

@Suite("InputSanitizer.sanitizeString — string escaping for AppleScript source values")
struct SanitizeStringTests {
    @Test("Escapes backslashes before quotes (order matters)")
    func escapesBackslashesBeforeQuotes() throws {
        // Input has a literal backslash followed by a quote: a\"b
        // Must escape \ first → a\\, then escape " → a\\\"b
        let result = try InputSanitizer.sanitizeString(#"a\"b"#)
        #expect(result == #"a\\\"b"#)
    }

    @Test("Escapes double quotes")
    func escapesDoubleQuotes() throws {
        let result = try InputSanitizer.sanitizeString(#"She said "hello""#)
        #expect(result == #"She said \"hello\""#)
    }

    @Test("Handles combined backslash and quote sequences")
    func combinedBackslashAndQuote() throws {
        // Input: path\to\"file" — contains both backslashes and quotes
        let result = try InputSanitizer.sanitizeString(#"path\to\"file""#)
        #expect(result == #"path\\to\\\"file\""#)
    }

    @Test("Throws emptyInput for empty string")
    func throwsOnEmpty() {
        #expect(throws: SanitizationError.self) {
            try InputSanitizer.sanitizeString("")
        }
    }

    @Test("Throws inputTooLarge for oversized string")
    func throwsOnOversized() {
        let oversized = String(repeating: "a", count: InputSanitizer.maxInputSize + 1)
        #expect(throws: SanitizationError.self) {
            try InputSanitizer.sanitizeString(oversized)
        }
    }

    @Test("Preserves Unicode characters (CJK, Cyrillic, emoji)")
    func preservesUnicode() throws {
        let cjk = try InputSanitizer.sanitizeString("日本語")
        #expect(cjk == "日本語")

        // Cyrillic: "Mir" (world) — verifies non-Latin scripts are preserved
        let cyrillic = try InputSanitizer.sanitizeString("Мир")
        #expect(cyrillic == "Мир")

        let emoji = try InputSanitizer.sanitizeString("🎵🎶")
        #expect(emoji == "🎵🎶")
    }

    @Test("Succeeds at exactly maxInputSize (boundary)")
    func succeedsAtBoundary() throws {
        let boundary = String(repeating: "x", count: InputSanitizer.maxInputSize)
        let result = try InputSanitizer.sanitizeString(boundary)
        #expect(result == boundary)
    }

    @Test("Returns plain string unchanged")
    func plainStringUnchanged() throws {
        let result = try InputSanitizer.sanitizeString("hello world")
        #expect(result == "hello world")
    }
}

// MARK: - sanitizeScriptCode

@Suite("InputSanitizer.sanitizeScriptCode — shell metacharacter stripping")
struct SanitizeScriptCodeTests {
    @Test("Strips individual metacharacters")
    func stripsIndividualShellMetacharacters() {
        #expect(InputSanitizer.sanitizeScriptCode("test;stop") == "teststop")
        #expect(InputSanitizer.sanitizeScriptCode("a|b") == "ab")
        #expect(InputSanitizer.sanitizeScriptCode("x&y") == "xy")
        #expect(InputSanitizer.sanitizeScriptCode("run`cmd`") == "runcmd")
        #expect(InputSanitizer.sanitizeScriptCode("$var") == "var")
        #expect(InputSanitizer.sanitizeScriptCode("call(x)") == "callx")
        #expect(InputSanitizer.sanitizeScriptCode("{block}") == "block")
    }

    @Test("Strips all metacharacters combined, leaving empty string")
    func allShellMetacharactersYieldEmpty() {
        let result = InputSanitizer.sanitizeScriptCode(";|&`$(){}")
        #expect(result.isEmpty)
    }

    @Test("Preserves non-metacharacter content")
    func preservesNonMetacharacterContent() {
        let result = InputSanitizer.sanitizeScriptCode("\"hello world\"")
        #expect(result == "\"hello world\"")
    }

    @Test("Empty input returns empty output")
    func emptyInputReturnsEmpty() {
        #expect(InputSanitizer.sanitizeScriptCode("").isEmpty)
    }

    @Test("Strips shell metacharacters from code with rm -rf")
    func stripsShellMetacharactersFromDangerousCode() {
        let sanitized = InputSanitizer.sanitizeScriptCode("test; rm -rf /")
        #expect(!sanitized.contains(";"))
    }

    @Test("Strips parentheses from code (NOT data)")
    func stripsParenthesesFromCode() {
        let result = InputSanitizer.sanitizeScriptCode("genre(test)")
        #expect(!result.contains("("))
        #expect(!result.contains(")"))
    }

    @Test("Strips metadata punctuation only when treating value as script code")
    func stripsMetadataPunctuationOnlyWhenTreatingValueAsScriptCode() {
        let value = #"Паліндром / Альбом, Частина & "Live" (EP) [Single]"#
        let escapedValue = #"Паліндром / Альбом, Частина & \"Live\" (EP) [Single]"#

        let codeSanitized = InputSanitizer.sanitizeScriptCode(value)

        #expect(!codeSanitized.contains("&"))
        #expect(!codeSanitized.contains("("))
        #expect(!codeSanitized.contains(")"))
        #expect(codeSanitized != escapedValue)
    }
}

// MARK: - escapeStringValue

@Suite("InputSanitizer.escapeStringValue — data value escaping (preserves all chars)")
struct EscapeStringValueTests {
    @Test("Escapes quotes and backslashes")
    func escapesQuotesAndBackslashes() {
        let result = InputSanitizer.escapeStringValue(#"She said "hello""#)
        #expect(result == #"She said \"hello\""#)

        let pathResult = InputSanitizer.escapeStringValue(#"path\to\file"#)
        #expect(pathResult == #"path\\to\\file"#)
    }

    @Test("Preserves parentheses, brackets, and curly braces (NOT stripped)")
    func preservesParenthesesAndBrackets() {
        let result = InputSanitizer.escapeStringValue("Song (feat. Artist) [Deluxe] {Remix}")
        #expect(result == "Song (feat. Artist) [Deluxe] {Remix}")
    }

    @Test("Escapes backslashes in Japanese text")
    func escapesBackslashesInJapanese() {
        let result = InputSanitizer.escapeStringValue(#"パス\テスト"#)
        #expect(result == #"パス\\テスト"#)
    }

    @Test("Handles mixed special characters in track metadata")
    func mixedSpecialChars() {
        let result = InputSanitizer.escapeStringValue(#"Track (Remaster) "2024" [Deluxe]"#)
        #expect(result == #"Track (Remaster) \"2024\" [Deluxe]"#)
    }

    @Test("Preserves metadata punctuation for source interpolation escaping")
    func preservesMetadataPunctuationForSourceInterpolationEscaping() {
        let value = #"Паліндром / Альбом, Частина & "Live" (EP) [Single]"#
        let escapedValue = #"Паліндром / Альбом, Частина & \"Live\" (EP) [Single]"#

        #expect(InputSanitizer.escapeStringValue(value) == escapedValue)
    }
}

// MARK: - sanitizeArguments

@Suite("InputSanitizer.sanitizeArguments — legacy source escaping")
struct SanitizeArgumentsTests {
    @Test("Preserves legacy source escaping and empty-input validation")
    @available(*, deprecated, message: "Exercises deprecated compatibility path.")
    func preservesLegacySourceEscapingAndEmptyInputValidation() throws {
        let result = try InputSanitizer.sanitizeArguments(["hello", #"wor"ld"#])
        #expect(result == ["hello", #"wor\"ld"#])

        #expect(throws: SanitizationError.self) {
            try InputSanitizer.sanitizeArguments([""])
        }
    }
}

// MARK: - validateScriptCode

@Suite("InputSanitizer.validateScriptCode — dangerous AppleScript pattern detection")
struct ValidateScriptCodeTests {
    @Test(
        "Detects dangerous AppleScript patterns",
        arguments: [
            #"do shell script "rm -rf /""#,
            #"tell application "Finder""#,
            #"tell application "System Events""#,
            #"load script file "evil.scpt""#,
            #"store script compiledScript in file "output.scpt""#,
            "choose file",
            "choose folder",
            #"open location "https://evil.com""#,
            #"keystroke "a""#,
            #"system attribute "HOME""#,
        ]
    )
    func detectsDangerousPatterns(input: String) {
        #expect(throws: SanitizationError.self) {
            try InputSanitizer.validateScriptCode(input)
        }
    }

    @Test("Detection is case-insensitive")
    func caseInsensitive() {
        #expect(throws: SanitizationError.self) {
            try InputSanitizer.validateScriptCode(#"DO SHELL SCRIPT "test""#)
        }
    }

    @Test("Detects key code pattern")
    func detectsKeyCode() {
        #expect(throws: SanitizationError.self) {
            try InputSanitizer.validateScriptCode("key code 36")
        }
    }

    @Test("Throws emptyInput for empty code")
    func throwsOnEmpty() {
        #expect(throws: SanitizationError.self) {
            try InputSanitizer.validateScriptCode("")
        }
    }

    @Test("Throws inputTooLarge for oversized code")
    func throwsOnOversized() {
        let oversized = String(repeating: "a", count: InputSanitizer.maxInputSize + 1)
        #expect(throws: SanitizationError.self) {
            try InputSanitizer.validateScriptCode(oversized)
        }
    }

    @Test("Safe code passes validation")
    func safeCodePasses() throws {
        try InputSanitizer.validateScriptCode(#"set trackName to "hello""#)
    }
}

// MARK: - validateAppleEventArguments

@Suite("InputSanitizer.validateAppleEventArguments — direct AppleEvent argv validation")
struct ValidateAppleEventArgumentsTests {
    @Test("Validates each argv element without escaping payload text")
    func validatesEachArgvElementWithoutEscapingPayloadText() throws {
        let result = try InputSanitizer.validateAppleEventArguments(["hello", #"wor"ld"#])
        #expect(result == ["hello", #"wor"ld"#])
    }

    @Test("Preserves empty string argv for direct AppleEvent callers")
    func preservesEmptyStringArgv() throws {
        let result = try InputSanitizer.validateAppleEventArguments([""])
        #expect(result == [""])
    }

    @Test("Empty array returns empty array")
    func emptyArrayReturnsEmpty() throws {
        let result = try InputSanitizer.validateAppleEventArguments([])
        #expect(result.isEmpty)
    }

    @Test("Preserves update_property metadata argv exactly")
    func preservesUpdatePropertyMetadataArgvExactly() throws {
        let value = #"Паліндром / Альбом, Частина & "Live" (EP) [Single]"#

        #expect(try InputSanitizer.validateAppleEventArguments(["42", "name", value]) == ["42", "name", value])
    }

    @Test("Propagates error when an element exceeds max size")
    func propagatesErrorOnOversizedElement() {
        let oversized = String(repeating: "x", count: InputSanitizer.maxInputSize + 1)

        #expect(throws: SanitizationError.self) {
            try InputSanitizer.validateAppleEventArguments(["valid", oversized])
        }
    }
}

// MARK: - validateFilePath

@Suite("InputSanitizer.validateFilePath — file path security validation")
struct ValidateFilePathTests {
    @Test("Throws on empty path")
    func throwsOnEmptyPath() {
        #expect(throws: SanitizationError.self) {
            try InputSanitizer.validateFilePath("", allowedExtensions: [".scpt"])
        }
    }

    @Test("Throws on directory traversal (..) in path")
    func throwsOnTraversal() {
        #expect(throws: SanitizationError.self) {
            try InputSanitizer.validateFilePath("/tmp/../etc/passwd", allowedExtensions: [".scpt"])
        }
    }

    @Test("Throws on wrong extension")
    func throwsOnWrongExtension() {
        #expect(throws: SanitizationError.self) {
            try InputSanitizer.validateFilePath("/tmp/evil.sh", allowedExtensions: [".scpt"])
        }
    }

    @Test("Accepts correct extension case-insensitively")
    func acceptsCorrectExtensionCaseInsensitive() throws {
        let lowercase = try InputSanitizer.validateFilePath("/tmp/script.scpt", allowedExtensions: ["scpt"])
        #expect(lowercase.pathExtension == "scpt")

        let uppercase = try InputSanitizer.validateFilePath("/tmp/script.SCPT", allowedExtensions: ["scpt"])
        #expect(uppercase.pathExtension == "SCPT")
    }

    @Test("Returns standardized URL")
    func returnsStandardizedURL() throws {
        let url = try InputSanitizer.validateFilePath("/tmp/./scripts/test.scpt", allowedExtensions: ["scpt"])
        #expect(url.isFileURL)
        // Standardized path removes the redundant `.` component
        #expect(!url.path().contains("/./"))
    }
}
