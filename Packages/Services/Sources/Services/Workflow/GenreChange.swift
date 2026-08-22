import Core
import Foundation

extension UpdateCoordinator {
    func determineGenreChange(
        track: Track,
        artistTracks: [Track],
        options: UpdateOptions
    ) async -> ProposedChange? {
        let clock = ContinuousClock()
        let start = clock.now
        let change = resolveGenreChange(
            track: track,
            artistTracks: artistTracks,
            options: options
        )
        if let analytics {
            await analytics.record(
                .genreDetermination,
                duration: start.duration(to: clock.now),
                outcome: .succeeded
            )
        }
        return change
    }

    private func resolveGenreChange(
        track: Track,
        artistTracks: [Track],
        options: UpdateOptions
    ) -> ProposedChange? {
        let canRepairExistingGenre = runtimeConfiguration.shouldOverrideExistingGenres
            || options.repairExistingGenreMismatches
        let canUpdateGenre = canRepairExistingGenre
            || Self.isMissingGenre(track.genre)
        guard options.updateGenre, canUpdateGenre else {
            return nil
        }

        let genreResult = genreDeterminator.determineDominantGenre(
            artistTracks: Self.genreSourceTracks(artistTracks),
            genreMappings: runtimeConfiguration.genreMappings
        )
        guard let newGenre = genreResult.genre,
              Self.hasGenreValueChanged(currentGenre: track.genre, newGenre: newGenre)
        else {
            return nil
        }

        return ProposedChange(
            track: track,
            changeType: .genreUpdate,
            oldValue: track.genre,
            newValue: newGenre,
            confidence: 80,
            source: "Library"
        )
    }

    private static func isMissingGenre(_ genre: String?) -> Bool {
        guard let genre else { return true }
        let normalizedGenre = genre.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedGenre.isEmpty || normalizedGenre == "unknown"
    }

    private static func genreSourceTracks(_ tracks: [Track]) -> [Track] {
        tracks.filter { !isMissingGenre($0.genre) }
    }

    private static func hasGenreValueChanged(currentGenre: String?, newGenre: String) -> Bool {
        let normalizedCurrentGenre = currentGenre?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedNewGenre = newGenre.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedCurrentGenre != normalizedNewGenre
    }
}
