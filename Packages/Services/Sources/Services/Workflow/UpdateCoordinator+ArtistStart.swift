// UpdateCoordinator+ArtistStart.swift — Artist start year plausibility guard

import Core
import Foundation

extension UpdateCoordinator {
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

        guard let artistStartYear = await apiOrchestrator.getArtistStartYear(
            normalizedArtist: track.effectiveArtist
        ) else {
            return false
        }

        return proposedYear < artistStartYear
    }
}
