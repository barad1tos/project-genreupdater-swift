import Core
import Foundation

extension UpdateCoordinator {
    func hasCachedYearMatch(
        track: Track,
        albumTracks: [Track],
        entry: AlbumCacheEntry?,
        context: YearDecisionContext
    ) -> Bool {
        guard let entry,
              let cachedYear = entry.year,
              let libraryYear = dominantLibraryYear(
                  in: albumContextTracks(track: track, albumTracks: albumTracks),
                  context: context
              )
        else {
            return false
        }
        return cachedYear == libraryYear
    }

    func hasStableYear(
        track: Track,
        albumTracks: [Track],
        entry: AlbumCacheEntry?,
        context: YearDecisionContext
    ) -> Bool {
        guard entry == nil else { return false }
        let tracks = albumContextTracks(track: track, albumTracks: albumTracks)
        guard let libraryYear = consistentLibraryYear(in: tracks) else {
            return false
        }
        return !shouldVerifyYear(
            libraryYear,
            tracks: tracks,
            decisionDate: context.decisionDate
        )
    }

    private func consistentLibraryYear(in tracks: [Track]) -> Int? {
        guard tracks.count >= 2 else { return nil }
        var consistentYear: Int?
        for track in tracks {
            guard let year = track.year,
                  case .valid = yearDeterminator.validator.validate(year: year)
            else {
                return nil
            }
            if let existingYear = consistentYear, existingYear != year {
                return nil
            }
            consistentYear = year
        }
        return consistentYear
    }

    func shouldVerifyYear(
        _ year: Int,
        tracks: [Track],
        decisionDate: Date
    ) -> Bool {
        let currentYear = Self.utcYear(at: decisionDate)
        guard year >= currentYear - 1 else { return false }
        return validReleaseYears(in: tracks).isEmpty
    }

    private func dominantLibraryYear(
        in tracks: [Track],
        context: YearDecisionContext
    ) -> Int? {
        var yearCounts: [Int: Int] = [:]
        var orderedYears: [Int] = []
        for track in tracks {
            guard let year = track.year,
                  context.candidateYearValidator.acceptsCandidateYear(year, at: context.decisionDate)
            else {
                continue
            }
            if yearCounts[year] == nil {
                orderedYears.append(year)
            }
            yearCounts[year, default: 0] += 1
        }

        var dominantYear: Int?
        for year in orderedYears {
            guard let currentDominantYear = dominantYear else {
                dominantYear = year
                continue
            }
            if yearCounts[year, default: 0] > yearCounts[currentDominantYear, default: 0] {
                dominantYear = year
            }
        }
        return dominantYear
    }
}
