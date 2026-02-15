import Testing
@testable import Core

@Suite("ScriptDetector")
struct ScriptDetectorTests {

    // MARK: - Individual Script Detection

    @Test("Detects Arabic script")
    func arabic() {
        #expect(hasArabic("محمد عبده"))
        #expect(!hasArabic("Pink Floyd"))
    }

    @Test("Detects Chinese characters")
    func chinese() {
        #expect(hasChinese("周杰伦"))
        #expect(!hasChinese("Pink Floyd"))
    }

    @Test("Detects Cyrillic script")
    func cyrillic() {
        #expect(hasCyrillic("МУР"))
        #expect(hasCyrillic("діти інженерів"))
        #expect(!hasCyrillic("Pink Floyd"))
    }

    @Test("Detects Devanagari script")
    func devanagari() {
        #expect(hasDevanagari("हिन्दी संगीत"))
        #expect(!hasDevanagari("Pink Floyd"))
    }

    @Test("Detects Greek script")
    func greek() {
        #expect(hasGreek("Μουσική"))
        #expect(!hasGreek("Pink Floyd"))
    }

    @Test("Detects Hebrew script")
    func hebrew() {
        #expect(hasHebrew("מוזיקה עברית"))
        #expect(!hasHebrew("Pink Floyd"))
    }

    @Test("Detects Japanese (hiragana, katakana, kanji)")
    func japanese() {
        #expect(hasJapanese("音楽"))
        #expect(hasJapanese("ひらがな"))
        #expect(hasJapanese("カタカナ"))
        #expect(!hasJapanese("Pink Floyd"))
    }

    @Test("Detects Korean script")
    func korean() {
        #expect(hasKorean("한국 음악"))
        #expect(!hasKorean("Pink Floyd"))
    }

    @Test("Detects Latin script")
    func latin() {
        #expect(hasLatin("Pink Floyd"))
        #expect(hasLatin("Café"))
        #expect(!hasLatin("МУР"))
        #expect(!hasLatin("123"))
        #expect(!hasLatin("!!!"))
    }

    @Test("Detects Thai script")
    func thai() {
        #expect(hasThai("เพลงไทย"))
        #expect(!hasThai("Pink Floyd"))
    }

    // MARK: - CJK Convenience

    @Test("isCJK detects Chinese, Japanese, Korean")
    func cjkConvenience() {
        #expect(isCJK("周杰伦"))
        #expect(isCJK("音楽"))
        #expect(isCJK("한국"))
        #expect(!isCJK("Pink Floyd"))
        #expect(!isCJK("МУР"))
    }

    // MARK: - Dominant Script Detection

    @Test("Pure Latin text")
    func dominantLatin() {
        #expect(dominantScript(of: "Pink Floyd") == .latin)
    }

    @Test("Pure Cyrillic text")
    func dominantCyrillic() {
        #expect(dominantScript(of: "МУР") == .cyrillic)
    }

    @Test("Japanese text with kana → Japanese")
    func dominantJapaneseWithKana() {
        #expect(dominantScript(of: "音楽のひらがな") == .japanese)
    }

    @Test("CJK Kanji only → Chinese (default)")
    func dominantChineseDefault() {
        #expect(dominantScript(of: "周杰伦") == .chinese)
    }

    @Test("Korean text")
    func dominantKorean() {
        #expect(dominantScript(of: "한국 음악") == .korean)
    }

    @Test("Mixed Cyrillic + Latin → mixed when both significant")
    func mixedCyrillicLatin() {
        // "МУРМУР feat John" — Cyrillic 6/14 ≈ 43%, Latin 8/14 ≈ 57%, both > 25%
        #expect(dominantScript(of: "МУРМУР feat John") == .mixed)
    }

    @Test("Mostly Latin with minor non-Latin → Latin")
    func mostlyLatin() {
        // Long Latin text with one Cyrillic char
        #expect(dominantScript(of: "Pink Floyd the best band Д") == .latin)
    }

    @Test("Empty string → unknown")
    func emptyStringUnknown() {
        #expect(dominantScript(of: "") == .unknown)
    }

    @Test("Numbers and punctuation only → unknown")
    func numbersOnlyUnknown() {
        #expect(dominantScript(of: "123!!!") == .unknown)
    }

    // MARK: - getAllScripts

    @Test("All scripts in pure text")
    func allScriptsPure() {
        let scripts = getAllScripts("Pink Floyd")
        #expect(scripts == [.latin])
    }

    @Test("All scripts in mixed text")
    func allScriptsMixed() {
        let scripts = getAllScripts("МУР feat. John")
        #expect(scripts.contains(.cyrillic))
        #expect(scripts.contains(.latin))
    }

    @Test("All scripts empty text")
    func allScriptsEmpty() {
        #expect(getAllScripts("").isEmpty)
    }

    // MARK: - isPrimarilyCyrillic

    @Test("Primarily Cyrillic detection")
    func primarilyCyrillic() {
        #expect(isPrimarilyCyrillic("МУР"))
        #expect(isPrimarilyCyrillic("МУР feat. John"))
        #expect(!isPrimarilyCyrillic("Pink Floyd"))
    }
}
