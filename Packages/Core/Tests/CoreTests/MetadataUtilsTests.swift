import Testing
@testable import Core

@Suite("MetadataUtils")
struct MetadataUtilsTests {
    // MARK: - isRemaster

    @Test("Detects remaster in text")
    func editionKeywordDetection() {
        #expect(isRemaster("Album (Remastered 2021)"))
        #expect(isRemaster("Song - Remaster"))
        #expect(!isRemaster("Normal Album"))
        #expect(!isRemaster(""))
    }

    @Test("Custom remaster keywords")
    func customEditionKeywords() {
        #expect(isRemaster("Album (Deluxe)", keywords: ["deluxe", "expanded"]))
        #expect(!isRemaster("Album (Deluxe)", keywords: ["remaster"]))
    }

    // MARK: - removeParenthesesWithKeywords

    @Test("Removes parenthetical segment with keyword")
    func removeParensBasic() {
        let result = removeParenthesesWithKeywords(
            "Album (Remastered 2021)",
            keywords: ["remaster", "remastered"]
        )
        #expect(result == "Album")
    }

    @Test("Removes bracket segment with keyword")
    func removeBracketsBasic() {
        let result = removeParenthesesWithKeywords(
            "Album [Deluxe Edition]",
            keywords: ["deluxe"]
        )
        #expect(result == "Album")
    }

    @Test("Nested parentheses removed correctly")
    func nestedParens() {
        let result = removeParenthesesWithKeywords(
            "Album (Reissue (2024))",
            keywords: ["reissue"]
        )
        #expect(result == "Album")
    }

    @Test("Non-matching segments preserved")
    func nonMatchingPreserved() {
        let result = removeParenthesesWithKeywords(
            "Album (feat. John)",
            keywords: ["remaster"]
        )
        #expect(result == "Album (feat. John)")
    }

    @Test("Multiple segments, only matching removed")
    func multipleSegments() {
        let result = removeParenthesesWithKeywords(
            "Album (feat. John) (Remastered)",
            keywords: ["remastered"]
        )
        #expect(result == "Album (feat. John)")
    }

    @Test("Empty name returns empty")
    func emptyName() {
        #expect(removeParenthesesWithKeywords("", keywords: ["remaster"]).isEmpty)
    }

    @Test("Empty keywords returns original")
    func emptyKeywords() {
        #expect(removeParenthesesWithKeywords("Album (Remastered)", keywords: []) == "Album (Remastered)")
    }

    // MARK: - stripAlbumSuffixes

    @Test("Removes configured suffix")
    func stripSuffixBasic() {
        let result = stripAlbumSuffixes("Album (Remastered)", suffixes: [" (Remastered)"])
        #expect(result == "Album")
    }

    @Test("Removes multiple suffixes iteratively")
    func stripMultipleSuffixes() {
        let result = stripAlbumSuffixes(
            "Album (Deluxe Edition) (Remastered)",
            suffixes: [" (Remastered)", " (Deluxe Edition)"]
        )
        #expect(result == "Album")
    }

    @Test("No matching suffix preserves original")
    func stripNoMatch() {
        let result = stripAlbumSuffixes("Normal Album", suffixes: [" (Remastered)"])
        #expect(result == "Normal Album")
    }

    @Test("Empty suffixes list preserves original")
    func stripEmptySuffixes() {
        #expect(stripAlbumSuffixes("Album", suffixes: []) == "Album")
    }

    // MARK: - cleanNames

    @Test("Cleans track and album names")
    func cleanNamesBasic() {
        let config = CleaningConfig()
        let (track, album) = cleanNames(
            artist: "Pink Floyd",
            trackName: "Song (Remastered 2011)",
            albumName: "Album (Remastered)",
            config: config
        )
        #expect(track == "Song")
        #expect(album == "Album")
    }

    @Test("Exception pair skips cleaning")
    func cleanNamesException() {
        var config = CleaningConfig()
        config.trackCleaningExceptions = [
            TrackCleaningException(artist: "Tool", album: "Lateralus (Remastered)"),
        ]
        let (_, album) = cleanNames(
            artist: "Tool",
            trackName: "Song (Remastered)",
            albumName: "Lateralus (Remastered)",
            config: config
        )
        #expect(album == "Lateralus (Remastered)")
    }

    @Test("Exception is case-insensitive")
    func cleanNamesExceptionCaseInsensitive() {
        var config = CleaningConfig()
        config.trackCleaningExceptions = [
            TrackCleaningException(artist: "tool", album: "lateralus (remastered)"),
        ]
        let (_, album) = cleanNames(
            artist: "TOOL",
            trackName: "Song",
            albumName: "LATERALUS (Remastered)",
            config: config
        )
        #expect(album == "LATERALUS (Remastered)")
    }

    @Test("No remaster content passes through unchanged")
    func cleanNamesNoChange() {
        let config = CleaningConfig()
        let (track, album) = cleanNames(
            artist: "Artist",
            trackName: "Song",
            albumName: "Album",
            config: config
        )
        #expect(track == "Song")
        #expect(album == "Album")
    }

    @Test("Album suffix removed after parentheses cleaning")
    func cleanNamesSuffixRemoval() {
        let config = CleaningConfig()
        let (_, album) = cleanNames(
            artist: "Artist",
            trackName: "Song",
            albumName: "Album Remaster",
            config: config
        )
        #expect(album == "Album")
    }
}
