import Testing
@testable import Core

private func makeCountryCandidate(country: String) -> ReleaseCandidate {
    ReleaseCandidate(
        artist: "X",
        album: "X",
        year: 2000,
        source: .musicBrainz,
        releaseType: .album,
        status: .official,
        country: country
    )
}

@Suite("YearScorer - Country Configuration")
struct YearScorerCountryConfigTests {
    @Test("Custom major market country gives configured bonus")
    func customMajorMarketCountry() {
        var yearLogic = YearLogicConfig()
        yearLogic.majorMarketCodes = ["br"]
        let scorer = YearScorer(yearLogic: yearLogic)
        let candidate = makeCountryCandidate(country: "BR")

        let result = scorer.scoreRelease(
            candidate,
            queryArtist: "X",
            queryAlbum: "X",
            artistCountry: "JP"
        )

        #expect(result.breakdown.country == scorer.config.countryMajorMarketBonus)
    }
}
