// UpdateCoordinator+YearDetermination.swift — Year update decision flow

import Core
import Foundation

extension UpdateCoordinator {
    func determineYearChange(
        track: Track,
        albumTracks: [Track]
    ) async throws -> ProposedChange? {
        let albumTypeInfo = runtimeConfiguration.albumTypeDetection.classifyAlbum(track.album)
        guard albumTypeInfo.strategy != .markAndSkip else { return nil }

        if let cached = await cache.getAlbumYear(artist: track.artist, album: track.album),
           Double(cached.confidence) >= runtimeConfiguration.minimumYearUpdateConfidence {
            return yearChangeFromCached(track: track, entry: cached)
        }

        if let localChange = yearChangeFromLocalDetermination(track: track, albumTracks: albumTracks) {
            return localChange
        }

        let apiDetermination = await determineYearFromAPI(
            track: track,
            albumTracks: albumTracks,
            albumTypeInfo: albumTypeInfo
        )

        guard let year = apiDetermination.yearResult.year, year != track.year else {
            return nil
        }
        guard Double(apiDetermination.yearResult.confidence) >= runtimeConfiguration.minimumYearUpdateConfidence else {
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

    private func determineYearFromAPI(
        track: Track,
        albumTracks: [Track],
        albumTypeInfo: AlbumTypeInfo
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
        let determination = yearDeterminator.determineYear(
            candidates: apiCandidates,
            track: track,
            albumTracks: albumTracks,
            currentYear: track.year,
            artistActivityPeriod: artistActivityPeriod,
            albumTypeInfo: albumTypeInfo
        )
        return (determination.yearResult, determination.source.rawValue.capitalized)
    }

    private func yearChangeFromCached(
        track: Track,
        entry: AlbumCacheEntry
    ) -> ProposedChange? {
        guard let year = entry.year, year != track.year else { return nil }
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
}
