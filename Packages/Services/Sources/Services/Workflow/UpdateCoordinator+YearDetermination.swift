// UpdateCoordinator+YearDetermination.swift — Year update decision flow

import Core
import Foundation

private struct ReleaseYearConflict {
    let verificationYear: Int
}

extension UpdateCoordinator {
    func determineYearChange(
        track: Track,
        albumTracks: [Track]
    ) async throws -> ProposedChange? {
        let albumTypeInfo = runtimeConfiguration.albumTypeDetection.classifyAlbum(track.album)
        guard albumTypeInfo.strategy != .markAndSkip else { return nil }

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

        if !hasAmbiguousReleaseYearSignal,
           let cachedChange = await yearChangeFromCache(
               track: track,
               releaseYearConflict: releaseYearConflict
           ) {
            return cachedChange
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

    private func yearChangeFromCache(
        track: Track,
        releaseYearConflict: ReleaseYearConflict?
    ) async -> ProposedChange? {
        let cached = await cache.getAlbumYear(artist: track.artist, album: track.album)
        return yearChangeFromCached(
            track: track,
            entry: cached,
            requiredYear: releaseYearConflict?.verificationYear
        )
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
