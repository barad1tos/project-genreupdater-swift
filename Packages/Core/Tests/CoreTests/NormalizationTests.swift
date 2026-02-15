import Testing
@testable import Core

@Suite("Normalization")
struct NormalizationTests {

    // MARK: - normalizeForMatching

    @Test("Strips whitespace and lowercases")
    func basicNormalization() {
        #expect(normalizeForMatching("  Vildhjarta  ") == "vildhjarta")
        #expect(normalizeForMatching("2CELLOS") == "2cellos")
        #expect(normalizeForMatching("AC/DC") == "ac/dc")
    }

    @Test("Empty and whitespace-only strings return empty")
    func emptyStrings() {
        #expect(normalizeForMatching("") == "")
        #expect(normalizeForMatching("   ") == "")
        #expect(normalizeForMatching("\t\n") == "")
    }

    @Test("Preserves diacritics (no stripping)")
    func diacritics() {
        #expect(normalizeForMatching("Café") == "café")
        #expect(normalizeForMatching("Björk") == "björk")
        #expect(normalizeForMatching("Mötley Crüe") == "mötley crüe")
    }

    @Test("CJK characters pass through unchanged")
    func cjkCharacters() {
        #expect(normalizeForMatching("周杰伦") == "周杰伦")
        #expect(normalizeForMatching("  音楽  ") == "音楽")
    }

    @Test("Cyrillic characters lowercased")
    func cyrillicCharacters() {
        #expect(normalizeForMatching("МУР") == "мур")
        #expect(normalizeForMatching("  Діти Інженерів  ") == "діти інженерів")
    }

    @Test("Mixed script strings normalized")
    func mixedScripts() {
        #expect(normalizeForMatching("МУР feat. John") == "мур feat. john")
    }

    @Test("Special characters preserved")
    func specialCharacters() {
        #expect(normalizeForMatching("Guns N' Roses") == "guns n' roses")
        #expect(normalizeForMatching("Rage Against the Machine!") == "rage against the machine!")
    }

    // MARK: - areNamesEqual

    @Test("Equal after normalization")
    func namesEqual() {
        #expect(areNamesEqual("Pink Floyd", "pink floyd"))
        #expect(areNamesEqual("  AC/DC  ", "ac/dc"))
        #expect(areNamesEqual("МУР", "мур"))
    }

    @Test("Not equal after normalization")
    func namesNotEqual() {
        #expect(!areNamesEqual("Pink Floyd", "Led Zeppelin"))
        #expect(!areNamesEqual("AC/DC", "ACDC"))
    }
}
