import Testing
@testable import Core

// MARK: - Genre Parity Tests

@Suite("Genre Parity — Python reference fixtures")
struct GenreParityTests {

    let determinator = GenreDeterminator()

    @Test("Genre determination matches Python for all fixture cases",
          arguments: try! loadGenreFixtures())
    func genreParity(fixture: GenreFixtureCase) {
        let tracks = fixture.tracks.map { $0.toTrack() }
        let result = determinator.determineDominantGenre(artistTracks: tracks)

        #expect(
            result.genre == fixture.expected.genre,
            "[\(fixture.id)] genre: got \(String(describing: result.genre)), expected \(String(describing: fixture.expected.genre))"
        )
        #expect(
            result.sourceAlbum == fixture.expected.sourceAlbum,
            "[\(fixture.id)] sourceAlbum: got \(String(describing: result.sourceAlbum)), expected \(String(describing: fixture.expected.sourceAlbum))"
        )
    }
}

private func loadGenreFixtures() throws -> [GenreFixtureCase] {
    try FixtureLoader.load("genre_reference")
}
