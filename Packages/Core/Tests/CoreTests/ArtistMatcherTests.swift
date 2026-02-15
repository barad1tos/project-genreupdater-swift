import Testing
@testable import Core

@Suite("ArtistMatcher")
struct ArtistMatcherTests {

    // MARK: - Extract Main Artist

    @Test("Solo artist passes through")
    func mainArtistSolo() {
        #expect(extractMainArtist("Pink Floyd") == "Pink Floyd")
    }

    @Test("feat. splits correctly")
    func mainArtistFeat() {
        #expect(extractMainArtist("Drake feat. Rihanna") == "Drake")
    }

    @Test("ft. splits correctly")
    func mainArtistFt() {
        #expect(extractMainArtist("Eminem ft. Dido") == "Eminem")
    }

    @Test("& splits correctly")
    func mainArtistAmpersand() {
        #expect(extractMainArtist("Daft Punk & Pharrell") == "Daft Punk")
    }

    @Test("vs. splits correctly")
    func mainArtistVs() {
        #expect(extractMainArtist("DJ Shadow vs. Cut Chemist") == "DJ Shadow")
    }

    @Test("with splits correctly")
    func mainArtistWith() {
        #expect(extractMainArtist("Tom Jones with Carla Thomas") == "Tom Jones")
    }

    @Test("Case-insensitive separator matching")
    func mainArtistCaseInsensitive() {
        #expect(extractMainArtist("Drake FEAT. Rihanna") == "Drake")
        #expect(extractMainArtist("Drake Feat. Rihanna") == "Drake")
    }

    @Test("Empty string returns empty")
    func mainArtistEmpty() {
        #expect(extractMainArtist("") == "")
        #expect(extractMainArtist("   ") == "")
    }

    // MARK: - Split Collaborators

    @Test("Single artist returns array with one element")
    func splitSingleArtist() {
        #expect(splitCollaborators("Pink Floyd") == ["Pink Floyd"])
    }

    @Test("Two collaborators with &")
    func splitTwoAmpersand() {
        #expect(splitCollaborators("Daft Punk & Pharrell") == ["Daft Punk", "Pharrell"])
    }

    @Test("Featured artist split")
    func splitFeatured() {
        #expect(splitCollaborators("Drake feat. Rihanna") == ["Drake", "Rihanna"])
    }

    @Test("Multiple separators split all")
    func splitMultiple() {
        let result = splitCollaborators("A & B feat. C")
        #expect(result == ["A", "B", "C"])
    }

    @Test("Empty string returns empty array")
    func splitEmpty() {
        #expect(splitCollaborators("").isEmpty)
    }

    // MARK: - Strip "The" Prefix

    @Test("Removes 'The ' prefix")
    func stripTheBasic() {
        #expect(stripThePrefix("The Beatles") == "Beatles")
    }

    @Test("Case insensitive removal")
    func stripTheCaseInsensitive() {
        #expect(stripThePrefix("THE WHO") == "WHO")
        #expect(stripThePrefix("the rolling stones") == "rolling stones")
    }

    @Test("No prefix passes through")
    func stripTheNoPrefix() {
        #expect(stripThePrefix("Pink Floyd") == "Pink Floyd")
    }

    @Test("Short name preserved")
    func stripTheShort() {
        #expect(stripThePrefix("The") == "The")
        #expect(stripThePrefix("Them") == "Them")
    }

    @Test("Empty returns empty")
    func stripTheEmpty() {
        #expect(stripThePrefix("") == "")
    }

    // MARK: - Featured Artist Extraction

    @Test("Extracts from parentheses")
    func featuredFromParens() {
        let result = extractFeaturedArtists("Song (feat. John)")
        #expect(result == ["John"])
    }

    @Test("Extracts from brackets")
    func featuredFromBrackets() {
        let result = extractFeaturedArtists("Song [ft. Jane]")
        #expect(result == ["Jane"])
    }

    @Test("Extracts multiple featured artists")
    func featuredMultiple() {
        let result = extractFeaturedArtists("Song (feat. John & Jane)")
        #expect(result == ["John", "Jane"])
    }

    @Test("No featured returns empty")
    func featuredNone() {
        #expect(extractFeaturedArtists("Normal Song").isEmpty)
    }

    @Test("Case insensitive feat detection")
    func featuredCaseInsensitive() {
        let result = extractFeaturedArtists("Song (FEAT. Artist)")
        #expect(result == ["Artist"])
    }

    @Test("featuring keyword works")
    func featuredFullKeyword() {
        let result = extractFeaturedArtists("Song (featuring Artist)")
        #expect(result == ["Artist"])
    }

    // MARK: - Artist Normalization

    @Test("Full normalization pipeline")
    func normalizeArtistFull() {
        let result = normalizeArtistForMatching("The Beatles feat. Billy Preston")
        #expect(result == "beatles")
    }

    @Test("Simple artist normalization")
    func normalizeArtistSimple() {
        let result = normalizeArtistForMatching("Pink Floyd")
        #expect(result == "pink floyd")
    }

    // MARK: - Fuzzy Artist Match

    @Test("Exact match after normalization")
    func fuzzyExactMatch() {
        #expect(fuzzyArtistMatch("The Beatles", "Beatles"))
    }

    @Test("Similar artists match")
    func fuzzySimilarMatch() {
        #expect(fuzzyArtistMatch("Led Zeppelin", "Led Zepplin"))
    }

    @Test("Different artists don't match")
    func fuzzyDifferentArtists() {
        #expect(!fuzzyArtistMatch("Pink Floyd", "Led Zeppelin"))
    }

    @Test("Collaboration collapses to main artist")
    func fuzzyCollaboration() {
        #expect(fuzzyArtistMatch("Drake feat. Rihanna", "Drake"))
    }

    @Test("CJK artists use exact match")
    func fuzzyCJKExact() {
        // These are different CJK strings — should not fuzzy match
        #expect(!fuzzyArtistMatch("椎名林檎", "椎名桜子"))
        // Identical CJK should match
        #expect(fuzzyArtistMatch("椎名林檎", "椎名林檎"))
    }
}
