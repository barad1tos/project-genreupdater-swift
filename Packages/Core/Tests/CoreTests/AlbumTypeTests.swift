import Testing
@testable import Core

@Suite("AlbumType")
struct AlbumTypeTests {
    // MARK: - Album Type Detection

    @Test("Normal album → .normal")
    func normalAlbum() {
        let info = detectAlbumType("Dark Side of the Moon")
        #expect(info.albumType == .normal)
        #expect(info.detectedPattern == nil)
        #expect(info.strategy == .normal)
    }

    @Test("Empty string → .normal")
    func emptyAlbum() {
        let info = detectAlbumType("")
        #expect(info.albumType == .normal)
    }

    @Test("B-Sides → .special with markAndSkip")
    func bsidesSpecial() {
        let info = detectAlbumType("Blue Stahli B-Sides")
        #expect(info.albumType == .special)
        #expect(info.detectedPattern == "b-sides")
        #expect(info.strategy == .markAndSkip)
    }

    @Test("Demo album → .special")
    func demoSpecial() {
        let info = detectAlbumType("Demo Vault: Wasteland")
        #expect(info.albumType == .special)
    }

    @Test("Unreleased → .special")
    func unreleasedSpecial() {
        let info = detectAlbumType("Unreleased Tracks")
        #expect(info.albumType == .special)
    }

    @Test("Greatest Hits → .compilation with markAndSkip")
    func greatestHitsCompilation() {
        let info = detectAlbumType("Greatest Hits")
        #expect(info.albumType == .compilation)
        #expect(info.strategy == .markAndSkip)
    }

    @Test("Best Of → .compilation")
    func bestOfCompilation() {
        let info = detectAlbumType("Best of Pink Floyd")
        #expect(info.albumType == .compilation)
    }

    @Test("Anthology → .compilation")
    func anthologyCompilation() {
        let info = detectAlbumType("The Complete Anthology")
        #expect(info.albumType == .compilation)
    }

    @Test("Remastered → .reissue with markAndUpdate")
    func reissueFromUpdatedEditionKeyword() {
        let info = detectAlbumType("Album (Remastered)")
        #expect(info.albumType == .reissue)
        #expect(info.strategy == .markAndUpdate)
    }

    @Test("Deluxe Edition → .reissue")
    func deluxeReissue() {
        let info = detectAlbumType("Album (Deluxe Edition)")
        #expect(info.albumType == .reissue)
    }

    @Test("Anniversary → .reissue")
    func anniversaryReissue() {
        let info = detectAlbumType("25th Anniversary Edition")
        #expect(info.albumType == .reissue)
    }

    @Test("Case insensitive matching")
    func caseInsensitive() {
        #expect(detectAlbumType("GREATEST HITS").albumType == .compilation)
        #expect(detectAlbumType("remastered").albumType == .reissue)
        #expect(detectAlbumType("B-SIDES").albumType == .special)
    }

    @Test("Hyphens normalized in matching")
    func hyphenNormalization() {
        #expect(detectAlbumType("Bonus-Tracks Collection").albumType == .special)
        #expect(detectAlbumType("Acoustic-Versions").albumType == .special)
    }

    @Test("Pattern in brackets detected")
    func bracketsDetected() {
        #expect(detectAlbumType("Album [Remastered]").albumType == .reissue)
        #expect(detectAlbumType("Album [Deluxe]").albumType == .reissue)
    }

    // MARK: - Priority: special > compilation > reissue

    @Test("Special pattern takes priority over compilation")
    func specialOverCompilation() {
        // "Bootleg" is special, checked before compilation
        let info = detectAlbumType("Bootleg Hits Collection")
        #expect(info.albumType == .special)
    }

    // MARK: - Convenience Functions

    @Test("isSpecialAlbum convenience")
    func isSpecialConvenience() {
        let (isSpecial, pattern) = isSpecialAlbum("Demo Vault")
        #expect(isSpecial)
        #expect(pattern != nil)

        let (isNormal, _) = isSpecialAlbum("Regular Album")
        #expect(!isNormal)
    }

    @Test("yearHandlingStrategy convenience")
    func strategyConvenience() {
        #expect(yearHandlingStrategy(for: "Normal Album") == .normal)
        #expect(yearHandlingStrategy(for: "B-Sides") == .markAndSkip)
        #expect(yearHandlingStrategy(for: "Remastered") == .markAndUpdate)
    }

    // MARK: - Enum Conformances

    @Test("AlbumType is CaseIterable with 4 cases")
    func albumTypeCases() {
        #expect(AlbumType.allCases.count == 4)
    }

    @Test("YearHandlingStrategy raw values")
    func strategyRawValues() {
        #expect(YearHandlingStrategy.normal.rawValue == "normal")
        #expect(YearHandlingStrategy.markAndSkip.rawValue == "markAndSkip")
        #expect(YearHandlingStrategy.markAndUpdate.rawValue == "markAndUpdate")
    }
}
