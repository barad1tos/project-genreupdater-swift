import Testing
@testable import Core

@Suite("YearScorer — Country")
struct YearCountryTests {
    private let scorer = YearScorer()

    @Test("Country artist match gives bonus")
    func countryArtistMatch() {
        let result = score(candidateCountry: "GB", artistCountry: "GB")

        #expect(result.breakdown.country == scorer.config.countryArtistMatchBonus)
    }

    @Test("Major market country gives smaller bonus")
    func countryMajorMarket() {
        let result = score(candidateCountry: "US", artistCountry: "JP")

        #expect(result.breakdown.country == scorer.config.countryMajorMarketBonus)
    }

    @Test("Unknown country gives no bonus")
    func countryNone() {
        let result = score(candidateCountry: nil, artistCountry: "GB")

        #expect(result.breakdown.country == 0)
    }

    @Test("UK country alias matches GB artist region")
    func countryAliasMatch() {
        let result = score(candidateCountry: "UK", artistCountry: "GB")

        #expect(result.breakdown.country == scorer.config.countryArtistMatchBonus)
    }

    private func score(candidateCountry: String?, artistCountry: String) -> ScoredRelease {
        let candidate = ReleaseCandidate(
            artist: "X",
            album: "X",
            year: 2000,
            source: .musicBrainz,
            country: candidateCountry
        )
        return scorer.scoreRelease(
            candidate,
            queryArtist: "X",
            queryAlbum: "X",
            artistCountry: artistCountry
        )
    }
}
