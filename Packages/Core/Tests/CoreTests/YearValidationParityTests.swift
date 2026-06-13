import Testing
@testable import Core

// MARK: - Year Validation Parity Tests

@Suite("Year Validation Parity — Python reference fixtures")
struct YearValidationParityTests {
    let validator = YearValidator()

    @Test("Dominant year matches Python")
    func dominantYear() throws {
        let fixtures: [ValidationFixtureCase] = try loadValidationFixtures()

        for fixture in fixtures {
            let tracks = fixture.tracks.map { $0.toTrack() }
            let result = validator.getDominantYear(tracks: tracks)

            #expect(
                result?.year == fixture.expected.dominantYear,
                "[\(fixture.id)] dominantYear: got \(String(describing: result?.year)), expected \(String(describing: fixture.expected.dominantYear))"
            )
        }
    }

    @Test("Most common year (mode) matches Python")
    func mostCommonYear() throws {
        let fixtures: [ValidationFixtureCase] = try loadValidationFixtures()

        for fixture in fixtures {
            let tracks = fixture.tracks.map { $0.toTrack() }
            let result = FixtureHelpers.mostCommonYear(tracks: tracks)

            #expect(
                result == fixture.expected.mostCommonYear,
                "[\(fixture.id)] mostCommonYear: got \(String(describing: result)), expected \(String(describing: fixture.expected.mostCommonYear))"
            )
        }
    }

    @Test("Consensus release year matches Python")
    func consensusReleaseYear() throws {
        let fixtures: [ValidationFixtureCase] = try loadValidationFixtures()

        for fixture in fixtures {
            let tracks = fixture.tracks.map { $0.toTrack() }
            let result = validator.getConsensusReleaseYear(tracks: tracks)

            #expect(
                result == fixture.expected.consensusReleaseYear,
                "[\(fixture.id)] consensusReleaseYear: got \(String(describing: result)), expected \(String(describing: fixture.expected.consensusReleaseYear))"
            )
        }
    }
}

private func loadValidationFixtures() throws -> [ValidationFixtureCase] {
    try FixtureLoader.load("year_validation_reference")
}
