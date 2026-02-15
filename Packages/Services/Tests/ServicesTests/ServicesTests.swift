import Testing
@testable import Services

@Suite("Services Package — Phase 1 Smoke Tests")
struct ServicesSmokeTests {
    @Test("sanitizeScriptCode strips shell metacharacters")
    func sanitizeScriptCodeBasic() {
        let sanitized = InputSanitizer.sanitizeScriptCode("test; rm -rf /")
        #expect(!sanitized.contains(";"))
    }
}

// MARK: - InputSanitizer Hotfix Tests

@Suite("InputSanitizer — escapeStringValue (hotfix)")
struct InputSanitizerEscapeTests {
    @Test("escapeStringValue preserves parentheses in track names")
    func preservesParentheses() {
        let result = InputSanitizer.escapeStringValue("Song (feat. Artist)")
        #expect(result == "Song (feat. Artist)", "Parentheses must NOT be stripped from track data")
    }

    @Test("escapeStringValue preserves curly braces")
    func preservesCurlyBraces() {
        let result = InputSanitizer.escapeStringValue("Title {Remix}")
        #expect(result == "Title {Remix}")
    }

    @Test("escapeStringValue escapes quotes")
    func escapesQuotes() {
        let result = InputSanitizer.escapeStringValue(#"She said "hello""#)
        #expect(result == #"She said \"hello\""#)
    }

    @Test("escapeStringValue escapes backslashes")
    func escapesBackslashes() {
        let result = InputSanitizer.escapeStringValue(#"path\to\file"#)
        #expect(result == #"path\\to\\file"#)
    }

    @Test("escapeStringValue handles mixed special characters")
    func mixedSpecialChars() {
        let result = InputSanitizer.escapeStringValue(#"Track (Remaster) "2024" [Deluxe]"#)
        #expect(result == #"Track (Remaster) \"2024\" [Deluxe]"#)
    }

    @Test("sanitizeScriptCode strips parentheses from code")
    func scriptCodeStripsParentheses() {
        let result = InputSanitizer.sanitizeScriptCode("genre(test)")
        #expect(!result.contains("("))
        #expect(!result.contains(")"))
    }
}
