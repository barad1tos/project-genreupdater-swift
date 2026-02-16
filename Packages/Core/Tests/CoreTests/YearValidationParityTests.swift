import Testing
@testable import Core

// MARK: - Year Validation Parity Tests

@Suite("Year Validation Parity — Python reference fixtures")
struct YearValidationParityTests {

    let validator = YearValidator()

    @Test("Dominant year matches Python",
          arguments: try! loadValidationFixtures())
    func dominantYear(fixture: ValidationFixtureCase) {
        let tracks = fixture.tracks.map { $0.toTrack() }
        let result = validator.getDominantYear(tracks: tracks)

        #expect(
            result?.year == fixture.expected.dominantYear,
            "[\(fixture.id)] dominantYear: got \(String(describing: result?.year)), expected \(String(describing: fixture.expected.dominantYear))"
        )
    }

    @Test("Most common year (mode) matches Python",
          arguments: try! loadValidationFixtures())
    func mostCommonYear(fixture: ValidationFixtureCase) {
        let tracks = fixture.tracks.map { $0.toTrack() }
        let result = FixtureHelpers.mostCommonYear(tracks: tracks)

        #expect(
            result == fixture.expected.mostCommonYear,
            "[\(fixture.id)] mostCommonYear: got \(String(describing: result)), expected \(String(describing: fixture.expected.mostCommonYear))"
        )
    }

    @Test("Consensus release year matches Python",
          arguments: try! loadValidationFixtures())
    func consensusReleaseYear(fixture: ValidationFixtureCase) {
        let tracks = fixture.tracks.map { $0.toTrack() }
        let result = validator.getConsensusReleaseYear(tracks: tracks)

        #expect(
            result == fixture.expected.consensusReleaseYear,
            "[\(fixture.id)] consensusReleaseYear: got \(String(describing: result)), expected \(String(describing: fixture.expected.consensusReleaseYear))"
        )
    }
}

private func loadValidationFixtures() throws -> [ValidationFixtureCase] {
    try FixtureLoader.load("year_validation_reference")
}
