// UpdateCoordinator+YearDetermination.swift — Year update decision flow

import Core
import Foundation

private struct ReleaseYearConflict {
    let verificationYear: Int
}

extension UpdateCoordinator {
    private static let fallbackRejectionReasons: Set<String> = [
        "suspicious_year_change",
        "implausible_existing_year",
        "absurd_year_no_existing",
        "special_album_compilation",
        "special_album_special",
        "special_album_reissue",
    ]

    func determineYearChange(
        track: Track,
        albumTracks: [Track]
    ) async throws -> ProposedChange? {
        let albumTypeInfo = runtimeConfiguration.albumTypeDetection.classifyAlbum(track.album)
        guard albumTypeInfo.strategy != .markAndSkip else { return nil }
        guard !isAlbumAlreadyProcessedByMGU(track: track, albumTracks: albumTracks) else { return nil }
        if await shouldSkipRecentFallbackRejection(track: track) { return nil }

        let releaseYearConflict = releaseYearConflict(
            for: track,
            albumTracks: albumTracks
        )
        let hasAmbiguousReleaseYearSignal = hasAmbiguousReleaseYearSignal(
            for: track,
            albumTracks: albumTracks
        )

        if shouldPreferLocalYearRepair(for: track),
           let localChange = yearChangeFromLocalDetermination(track: track, albumTracks: albumTracks) {
            return localChange
        }

        let cachedAlbumYear = await cache.getAlbumYear(artist: track.artist, album: track.album)

        if !hasAmbiguousReleaseYearSignal {
            if releaseYearConflict == nil,
               shouldSkipYearLookupFromCachedAlbumYear(
                   track: track,
                   albumTracks: albumTracks,
                   entry: cachedAlbumYear
               ) {
                return nil
            }

            if let cachedChange = yearChangeFromCached(
                track: track,
                entry: cachedAlbumYear,
                requiredYear: releaseYearConflict?.verificationYear
            ) {
                return cachedChange
            }
        }

        if releaseYearConflict == nil,
           !hasAmbiguousReleaseYearSignal,
           shouldSkipYearLookupFromUncachedConsistentAlbumYear(
               track: track,
               albumTracks: albumTracks,
               entry: cachedAlbumYear
           ) {
            return nil
        }

        if releaseYearConflict == nil,
           !hasAmbiguousReleaseYearSignal,
           let localChange = yearChangeFromLocalDetermination(track: track, albumTracks: albumTracks) {
            return localChange
        }

        let apiDetermination = await determineYearFromAPI(
            track: track,
            albumTracks: albumTracks,
            albumTypeInfo: albumTypeInfo,
            ignoreLocalAlbumYears: releaseYearConflict != nil || hasAmbiguousReleaseYearSignal
        )

        return await yearChangeFromAPIDetermination(
            track: track,
            apiDetermination: apiDetermination,
            releaseYearConflict: releaseYearConflict
        )
    }

    private func albumContextTracks(track: Track, albumTracks: [Track]) -> [Track] {
        albumTracks.contains { $0.id == track.id } ? albumTracks : albumTracks + [track]
    }

    private func isAlbumAlreadyProcessedByMGU(track: Track, albumTracks: [Track]) -> Bool {
        let tracks = albumContextTracks(track: track, albumTracks: albumTracks)
        guard let processedYear = tracks.first?.yearSetByMGU else { return false }

        return tracks.allSatisfy { albumTrack in
            albumTrack.yearSetByMGU == processedYear && albumTrack.year == processedYear
        }
    }

    private func shouldSkipRecentFallbackRejection(track: Track) async -> Bool {
        guard let pendingVerificationService else { return false }
        guard let entry = await pendingVerificationService.getEntry(
            artist: track.artist,
            album: track.album
        ) else {
            return false
        }
        guard Self.fallbackRejectionReasons.contains(entry.reason) else {
            return false
        }

        let isVerificationNeeded = await pendingVerificationService.isVerificationNeeded(
            artist: track.artist,
            album: track.album
        )
        return !isVerificationNeeded
    }

    private func shouldSkipYearLookupFromCachedAlbumYear(
        track: Track,
        albumTracks: [Track],
        entry: AlbumCacheEntry?
    ) -> Bool {
        guard let entry,
              let cachedYear = entry.year,
              let libraryYear = dominantValidLibraryYear(
                  in: albumContextTracks(track: track, albumTracks: albumTracks)
              )
        else {
            return false
        }

        return cachedYear == libraryYear
    }

    private func shouldSkipYearLookupFromUncachedConsistentAlbumYear(
        track: Track,
        albumTracks: [Track],
        entry: AlbumCacheEntry?
    ) -> Bool {
        guard entry == nil else { return false }
        let tracks = albumContextTracks(track: track, albumTracks: albumTracks)
        guard let libraryYear = consistentValidLibraryYear(in: tracks) else {
            return false
        }
        return !requiresAPIVerificationForRecentYearWithoutReleaseSignal(
            libraryYear,
            tracks: tracks
        )
    }

    private func consistentValidLibraryYear(in tracks: [Track]) -> Int? {
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

    private func requiresAPIVerificationForRecentYearWithoutReleaseSignal(
        _ year: Int,
        tracks: [Track]
    ) -> Bool {
        let currentYear = Calendar.current.component(.year, from: Date())
        guard year >= currentYear - 1 else { return false }
        return validReleaseYears(in: tracks).isEmpty
    }

    private func dominantValidLibraryYear(in tracks: [Track]) -> Int? {
        var yearCounts: [Int: Int] = [:]
        var orderedYears: [Int] = []
        for track in tracks {
            guard let year = track.year,
                  isValidLibraryYearForCacheComparison(year)
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

    private func isValidLibraryYearForCacheComparison(_ year: Int) -> Bool {
        let currentYear = Calendar.current.component(.year, from: Date())
        return year >= yearDeterminator.validator.config.minValidYear && year <= currentYear
    }

    private func shouldPreferLocalYearRepair(for track: Track) -> Bool {
        guard let year = track.year else { return false }
        if case .valid = yearDeterminator.validator.validate(year: year) {
            return false
        }
        return true
    }

    private func determineYearFromAPI(
        track: Track,
        albumTracks: [Track],
        albumTypeInfo: AlbumTypeInfo,
        ignoreLocalAlbumYears: Bool = false
    ) async -> (yearResult: YearResult, sourceLabel: String) {
        let earliestTrackAddedYear = earliestAddedYear(albumTracks)
        let apiCandidates = await apiOrchestrator.getReleaseCandidates(
            artist: track.artist,
            album: track.album,
            currentLibraryYear: track.year,
            earliestTrackAddedYear: earliestTrackAddedYear
        )

        guard !apiCandidates.isEmpty else {
            let yearResult = await apiOrchestrator.getAlbumYear(
                artist: track.artist,
                album: track.album,
                currentLibraryYear: track.year,
                earliestTrackAddedYear: earliestTrackAddedYear
            )
            return (yearResult, yearResult.isDefinitive ? "Definitive" : "API")
        }

        let artistActivityPeriod = await apiOrchestrator.getArtistActivityPeriod(
            normalizedArtist: normalizeForMatching(track.effectiveArtist)
        )
        let scoringAlbumTracks = ignoreLocalAlbumYears ? [] : albumTracks
        let determination = yearDeterminator.determineYear(
            candidates: apiCandidates,
            track: track,
            albumTracks: scoringAlbumTracks,
            currentYear: track.year,
            artistActivityPeriod: artistActivityPeriod,
            albumTypeInfo: albumTypeInfo
        )
        return (determination.yearResult, determination.source.rawValue.capitalized)
    }

    private func yearChangeFromAPIDetermination(
        track: Track,
        apiDetermination: (yearResult: YearResult, sourceLabel: String),
        releaseYearConflict: ReleaseYearConflict?
    ) async -> ProposedChange? {
        guard let year = apiDetermination.yearResult.year, year != track.year else {
            return nil
        }
        guard Double(apiDetermination.yearResult.confidence) >= runtimeConfiguration.minimumYearUpdateConfidence else {
            return nil
        }
        if let releaseYearConflict, releaseYearConflict.verificationYear != year {
            return nil
        }

        if await shouldPreserveExistingYearForArtistStart(
            track: track,
            proposedYear: year,
            yearResult: apiDetermination.yearResult
        ) {
            return nil
        }

        if apiDetermination.yearResult.confidence >= runtimeConfiguration.minimumConfidenceToCache {
            await cache.storeAlbumYear(
                artist: track.artist,
                album: track.album,
                year: year,
                confidence: apiDetermination.yearResult.confidence
            )
        }

        return ProposedChange(
            track: track,
            changeType: .yearUpdate,
            oldValue: track.year.map(String.init),
            newValue: String(year),
            confidence: apiDetermination.yearResult.confidence,
            source: apiDetermination.sourceLabel
        )
    }

    private func yearChangeFromCached(
        track: Track,
        entry: AlbumCacheEntry?,
        requiredYear: Int? = nil
    ) -> ProposedChange? {
        guard let entry,
              let year = entry.year,
              year != track.year,
              Double(entry.confidence) >= runtimeConfiguration.minimumYearUpdateConfidence
        else {
            return nil
        }
        if let requiredYear, year != requiredYear {
            return nil
        }

        return ProposedChange(
            track: track,
            changeType: .yearUpdate,
            oldValue: track.year.map(String.init),
            newValue: String(year),
            confidence: entry.confidence,
            source: "Cache"
        )
    }

    private func yearChangeFromLocalDetermination(
        track: Track,
        albumTracks: [Track]
    ) -> ProposedChange? {
        guard !albumTracks.isEmpty else { return nil }

        let determination = yearDeterminator.determineYear(
            candidates: [],
            track: track,
            albumTracks: albumTracks
        )
        let yearResult = determination.yearResult

        guard Double(yearResult.confidence) >= runtimeConfiguration.minimumYearUpdateConfidence,
              let year = yearResult.year,
              year != track.year
        else {
            return nil
        }

        return ProposedChange(
            track: track,
            changeType: .yearUpdate,
            oldValue: track.year.map(String.init),
            newValue: String(year),
            confidence: yearResult.confidence,
            source: determination.source.rawValue.capitalized
        )
    }

    func earliestAddedYear(_ tracks: [Track]) -> Int? {
        tracks
            .compactMap(\.dateAdded)
            .min()
            .map { Calendar.current.component(.year, from: $0) }
    }

    private func releaseYearConflict(
        for track: Track,
        albumTracks: [Track]
    ) -> ReleaseYearConflict? {
        guard let currentYear = track.year,
              case .valid = yearDeterminator.validator.validate(year: currentYear)
        else {
            return nil
        }

        let contextTracks = albumTracks.isEmpty ? [track] : albumTracks
        guard let verificationYear = releaseYearSignal(for: track, contextTracks: contextTracks),
              verificationYear != currentYear
        else {
            return nil
        }

        return ReleaseYearConflict(
            verificationYear: verificationYear
        )
    }

    private func releaseYearSignal(
        for track: Track,
        contextTracks: [Track]
    ) -> Int? {
        if let consensusYear = consensusReleaseYear(in: contextTracks) {
            return consensusYear
        }

        guard validReleaseYears(in: contextTracks).count <= 1 else {
            return nil
        }

        guard let releaseYear = track.releaseYear,
              case .valid = yearDeterminator.validator.validate(year: releaseYear)
        else {
            return nil
        }

        return releaseYear
    }

    private func hasAmbiguousReleaseYearSignal(
        for track: Track,
        albumTracks: [Track]
    ) -> Bool {
        let contextTracks = albumTracks.isEmpty ? [track] : albumTracks
        return validReleaseYears(in: contextTracks).count > 1
    }

    private func validReleaseYears(in tracks: [Track]) -> Set<Int> {
        Set(tracks.compactMap { track in
            guard let releaseYear = track.releaseYear,
                  case .valid = yearDeterminator.validator.validate(year: releaseYear)
            else {
                return nil
            }
            return releaseYear
        })
    }

    private func consensusReleaseYear(in tracks: [Track]) -> Int? {
        guard !tracks.isEmpty,
              tracks.allSatisfy({ $0.releaseYear != nil }),
              let consensus = yearDeterminator.validator.getConsensusReleaseYear(tracks: tracks),
              case .valid = yearDeterminator.validator.validate(year: consensus)
        else {
            return nil
        }
        return consensus
    }
}
