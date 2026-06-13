import Testing
@testable import Core

@Suite("AlbumMatcher")
struct AlbumMatcherTests {
    // MARK: - Levenshtein Distance

    @Test("Identical strings → 0")
    func levenshteinIdentical() {
        #expect(levenshteinDistance("hello", "hello") == 0)
    }

    @Test("Empty strings → 0")
    func levenshteinEmpty() {
        #expect(levenshteinDistance("", "") == 0)
    }

    @Test("One empty string → length of other")
    func levenshteinOneEmpty() {
        #expect(levenshteinDistance("", "hello") == 5)
        #expect(levenshteinDistance("hello", "") == 5)
    }

    @Test("Single character difference → 1")
    func levenshteinOneDiff() {
        #expect(levenshteinDistance("cat", "bat") == 1)
        #expect(levenshteinDistance("cat", "cats") == 1)
        #expect(levenshteinDistance("cat", "ca") == 1)
    }

    @Test("Completely different strings")
    func levenshteinDifferent() {
        #expect(levenshteinDistance("abc", "xyz") == 3)
    }

    @Test("Case sensitivity")
    func levenshteinCaseSensitive() {
        #expect(levenshteinDistance("Hello", "hello") == 1)
    }

    // MARK: - Normalized Similarity

    @Test("Identical → 1.0")
    func similarityIdentical() {
        #expect(normalizedSimilarity("hello", "hello") == 1.0)
    }

    @Test("Both empty → 1.0")
    func similarityBothEmpty() {
        #expect(normalizedSimilarity("", "") == 1.0)
    }

    @Test("Completely different → 0.0")
    func similarityDifferent() {
        #expect(normalizedSimilarity("abc", "xyz") == 0.0)
    }

    @Test("Partial similarity in range")
    func similarityPartial() {
        let sim = normalizedSimilarity("kitten", "sitting")
        #expect(sim > 0.0)
        #expect(sim < 1.0)
    }

    // MARK: - Fuzzy Album Match

    @Test("Exact match after normalization")
    func fuzzyExactMatch() {
        #expect(fuzzyAlbumMatch("Dark Side of the Moon", "dark side of the moon"))
    }

    @Test("Similar albums match above threshold")
    func fuzzySimilarMatch() {
        #expect(fuzzyAlbumMatch("Dark Side of the Moon", "Dark Side Of The Moon"))
    }

    @Test("Different albums don't match")
    func fuzzyDifferentAlbums() {
        #expect(!fuzzyAlbumMatch("Dark Side of the Moon", "The Wall"))
    }

    @Test("Custom threshold")
    func fuzzyCustomThreshold() {
        // Very low threshold accepts everything
        #expect(fuzzyAlbumMatch("ABC", "XYZ", threshold: 0.0))
        // Very high threshold rejects minor differences
        #expect(!fuzzyAlbumMatch("Album", "Albums", threshold: 1.0))
    }

    // MARK: - Album Variant Detection

    @Test("Remastered variant detected")
    func variantFromUpdatedEditionKeyword() {
        #expect(isAlbumVariant("Dark Side of the Moon", "Dark Side of the Moon (Remastered)"))
    }

    @Test("Deluxe variant detected")
    func variantDeluxe() {
        #expect(isAlbumVariant("Album", "Album (Deluxe Edition)"))
    }

    @Test("Different albums are not variants")
    func variantDifferentAlbums() {
        #expect(!isAlbumVariant("Dark Side of the Moon", "The Wall"))
    }

    @Test("Both clean albums compared")
    func variantBothClean() {
        #expect(isAlbumVariant("Album", "Album"))
    }

    // MARK: - Strip Disc Number

    @Test("Disc N removed")
    func stripDiscBasic() {
        #expect(stripDiscNumber("Album Disc 1") == "Album")
        #expect(stripDiscNumber("Album Disc 2") == "Album")
    }

    @Test("CD N removed")
    func stripCDNumber() {
        #expect(stripDiscNumber("Album CD1") == "Album")
        #expect(stripDiscNumber("Album CD 2") == "Album")
    }

    @Test("Disk N removed")
    func stripDiskNumber() {
        #expect(stripDiscNumber("Album Disk 1") == "Album")
    }

    @Test("No disc number preserves original")
    func stripNoDiscNumber() {
        #expect(stripDiscNumber("Normal Album") == "Normal Album")
    }

    @Test("Case insensitive disc removal")
    func stripDiscCaseInsensitive() {
        #expect(stripDiscNumber("Album DISC 1") == "Album")
        #expect(stripDiscNumber("Album disc 3") == "Album")
    }

    // MARK: - Normalize Album For Comparison

    @Test("Full normalization pipeline")
    func normalizeForComparisonFull() {
        let result = normalizeAlbumForComparison("Album (Remastered 2021) Disc 1")
        #expect(result == "album")
    }

    @Test("Clean album passes through")
    func normalizeForComparisonClean() {
        let result = normalizeAlbumForComparison("Dark Side of the Moon")
        #expect(result == "dark side of the moon")
    }
}
