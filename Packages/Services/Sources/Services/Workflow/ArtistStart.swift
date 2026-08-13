import Core
import Foundation

extension UpdateCoordinator {
    func markImplausibleYear(
        track: Track,
        year: Int,
        yearResult: YearResult
    ) async {
        guard yearDeterminator.fallback.config.enabled,
              !yearResult.isDefinitive,
              yearResult.yearScores[year] != nil
        else {
            return
        }

        let normalizedArtist = normalizeForMatching(AlbumIdentity.primaryArtist(for: track))
        guard let artistStartYear = await apiOrchestrator.getArtistStartYear(normalizedArtist: normalizedArtist),
              year < artistStartYear
        else {
            return
        }

        let identity = track.albumIdentity
        await pendingVerificationService?.markForVerification(
            artist: identity.artist,
            album: identity.album,
            reason: "implausible_matching_year",
            metadata: [
                "artist_start_year": String(artistStartYear),
                "note": "Both library and API returned same impossible year",
                "plausibility": "year_before_artist_start",
                "year": String(year),
            ],
            recheckDays: nil
        )
    }

    func shouldPreserveExistingYearForArtistStart(
        track: Track,
        proposedYear: Int,
        yearResult: YearResult
    ) async -> Bool {
        let fallbackConfig = yearDeterminator.fallback.config
        guard fallbackConfig.enabled,
              let existingYear = track.year
        else {
            return false
        }

        let difference = abs(proposedYear - existingYear)
        guard difference > fallbackConfig.yearDifferenceThreshold,
              Double(yearResult.confidence) < fallbackConfig.trustAPIScoreThreshold,
              yearResult.yearScores[existingYear] != nil
        else {
            return false
        }

        let normalizedArtist = normalizeForMatching(AlbumIdentity.primaryArtist(for: track))
        guard let artistStartYear = await apiOrchestrator.getArtistStartYear(normalizedArtist: normalizedArtist) else {
            return false
        }

        return proposedYear < artistStartYear
    }
}
