// YearDetermination.swift — Year update decision flow

import Core
import Foundation

private struct ReleaseYearConflict {
    let verificationYear: Int
}

private enum YearShortcutDecision {
    case continueToAPI
    case skip
    case change(ProposedChange)
}

extension UpdateCoordinator {
    private static let fallbackRejectionReasons: Set<String> = [
        "suspicious_year_change",
        "implausible_existing_year",
        "implausible_matching_year",
        "absurd_year_no_existing",
        "special_album_compilation",
        "special_album_special",
        "special_album_reissue",
    ]

    func determineYearChange(
        track: Track,
        albumTracks: [Track],
        forceYearLookup: Bool = false
    ) async throws -> ProposedChange? {
        let albumTypeInfo = runtimeConfiguration.albumTypeDetection.classifyAlbum(track.album)
        return try await determineYearChange(
            track: track,
            albumTracks: albumTracks,
            forceYearLookup: forceYearLookup,
            albumTypeInfo: albumTypeInfo
        )
    }

    func determineYearChange(
        track: Track,
        albumTracks: [Track],
        forceYearLookup: Bool,
        albumTypeInfo: AlbumTypeInfo,
        queryAlbum: String? = nil
    ) async throws -> ProposedChange? {
        guard albumTypeInfo.strategy != .markAndSkip else { return nil }
        if await shouldSkipYearPreflight(
            track: track,
            albumTracks: albumTracks,
            forceYearLookup: forceYearLookup
        ) {
            return nil
        }

        let releaseYearConflict = releaseYearConflict(
            for: track,
            albumTracks: albumTracks
        )
        let hasAmbiguousReleaseYearSignal = hasAmbiguousReleaseYearSignal(
            for: track,
            albumTracks: albumTracks
        )

        switch await yearShortcutDecision(
            track: track,
            albumTracks: albumTracks,
            forceYearLookup: forceYearLookup,
            releaseYearConflict: releaseYearConflict,
            hasAmbiguousReleaseYearSignal: hasAmbiguousReleaseYearSignal
        ) {
        case .continueToAPI:
            break
        case .skip:
            return nil
        case let .change(change):
            return change
        }

        let apiDetermination = await determineYearFromAPI(
            track: track,
            albumTracks: albumTracks,
            albumTypeInfo: albumTypeInfo,
            queryAlbum: queryAlbum ?? track.album,
            ignoreLocalAlbumYears: forceYearLookup || releaseYearConflict != nil || hasAmbiguousReleaseYearSignal
        )

        return await yearChangeFromAPIDetermination(
            track: track,
            albumTracks: albumTracks,
            apiDetermination: apiDetermination,
            releaseYearConflict: releaseYearConflict
        )
    }

    private func shouldSkipYearPreflight(
        track: Track,
        albumTracks: [Track],
        forceYearLookup: Bool
    ) async -> Bool {
        guard !forceYearLookup else { return false }
        if isAlbumAlreadyProcessedByMGU(track: track, albumTracks: albumTracks) {
            return true
        }
        return await shouldSkipRecentFallbackRejection(track: track)
    }

    private func yearShortcutDecision(
        track: Track,
        albumTracks: [Track],
        forceYearLookup: Bool,
        releaseYearConflict: ReleaseYearConflict?,
        hasAmbiguousReleaseYearSignal: Bool
    ) async -> YearShortcutDecision {
        guard !forceYearLookup else { return .continueToAPI }

        if let dominant = yearDeterminator.dominantDetermination(
            albumTracks: albumTracks,
            candidateCount: 0
        ), let change = yearChange(track: track, determination: dominant) {
            return .change(change)
        }

        let cachedAlbumYear = await cachedAlbumYear(for: track)
        if let decision = cachedDecision(
            track: track,
            albumTracks: albumTracks,
            entry: cachedAlbumYear,
            releaseYearConflict: releaseYearConflict,
            hasAmbiguousReleaseYearSignal: hasAmbiguousReleaseYearSignal
        ) {
            return decision
        }

        if releaseYearConflict == nil,
           !hasAmbiguousReleaseYearSignal,
           shouldSkipYearLookupFromUncachedConsistentAlbumYear(
               track: track,
               albumTracks: albumTracks,
               entry: cachedAlbumYear
           ) {
            return .skip
        }

        if releaseYearConflict == nil,
           let decision = await consensusDecision(
               track: track,
               albumTracks: albumTracks
           ) {
            return decision
        }

        return .continueToAPI
    }

    private func cachedAlbumYear(for track: Track) async -> AlbumCacheEntry? {
        for identity in AlbumIdentity.lookupCandidates(for: track) {
            if let entry = await cache.getAlbumYear(artist: identity.artist, album: identity.album) {
                return entry
            }
        }
        return nil
    }

    private func cachedDecision(
        track: Track,
        albumTracks: [Track],
        entry: AlbumCacheEntry?,
        releaseYearConflict: ReleaseYearConflict?,
        hasAmbiguousReleaseYearSignal: Bool
    ) -> YearShortcutDecision? {
        let isTrusted = isTrustedCacheEntry(entry)
        if releaseYearConflict == nil,
           !hasAmbiguousReleaseYearSignal || isTrusted,
           shouldSkipYearLookupFromCachedAlbumYear(
               track: track,
               albumTracks: albumTracks,
               entry: entry
           ) {
            return .skip
        }

        guard isTrusted else { return nil }
        if let cachedChange = yearChangeFromCached(
            track: track,
            entry: entry,
            requiredYear: releaseYearConflict?.verificationYear
        ) {
            return .change(cachedChange)
        }
        return nil
    }

    private func isTrustedCacheEntry(_ entry: AlbumCacheEntry?) -> Bool {
        guard let entry else { return false }
        return entry.confidence >= runtimeConfiguration.cacheTrustThreshold
    }

    private func consensusDecision(
        track: Track,
        albumTracks: [Track]
    ) async -> YearShortcutDecision? {
        guard let consensus = yearDeterminator.consensusDetermination(
            albumTracks: albumTracks,
            candidateCount: 0
        ), let year = consensus.yearResult.year
        else {
            return nil
        }

        let identity = track.albumIdentity
        await cache.storeAlbumYear(
            artist: identity.artist,
            album: identity.album,
            year: year,
            confidence: consensus.yearResult.confidence
        )

        if let change = yearChange(track: track, determination: consensus) {
            return .change(change)
        }
        return year == track.year ? .skip : nil
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
        for identity in AlbumIdentity.lookupCandidates(for: track) {
            guard let entry = await pendingVerificationService.getEntry(
                artist: identity.artist,
                album: identity.album
            ) else {
                continue
            }
            guard Self.fallbackRejectionReasons.contains(entry.reason) else {
                continue
            }

            let isVerificationNeeded = await pendingVerificationService.isVerificationNeeded(
                artist: identity.artist,
                album: identity.album
            )
            if !isVerificationNeeded {
                return true
            }
        }
        return false
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

    private func determineYearFromAPI(
        track: Track,
        albumTracks: [Track],
        albumTypeInfo: AlbumTypeInfo,
        queryAlbum: String,
        ignoreLocalAlbumYears: Bool = false
    ) async -> (yearResult: YearResult, sourceLabel: String) {
        let earliestTrackAddedYear = earliestAddedYear(albumTracks)
        let identity = AlbumIdentity(
            artist: AlbumIdentity.groupingArtist(for: track),
            album: queryAlbum
        )
        let apiCandidates = await apiOrchestrator.getReleaseCandidates(
            artist: identity.artist,
            album: identity.album,
            currentLibraryYear: track.year,
            earliestTrackAddedYear: earliestTrackAddedYear
        )

        guard !apiCandidates.isEmpty else {
            let pendingRemovalAliases = (
                AlbumIdentity.lookupCandidates(for: track) +
                    AlbumIdentity.lookupCandidates(artist: identity.artist, album: identity.album)
            ).map {
                (artist: $0.artist, album: $0.album)
            }
            let yearResult = await apiOrchestrator.getAlbumYear(
                artist: identity.artist,
                album: identity.album,
                currentLibraryYear: track.year,
                earliestTrackAddedYear: earliestTrackAddedYear,
                pendingRemovalAliases: pendingRemovalAliases
            )
            return (yearResult, yearResult.isDefinitive ? "Definitive" : "API")
        }

        let normalizedArtist = normalizeForMatching(identity.artist)
        let artistActivityPeriod = await apiOrchestrator.getArtistActivityPeriod(
            normalizedArtist: normalizedArtist
        )
        // Python parity (orchestrator.py:1079): the artist's region rides
        // next to the activity period into release-country scoring.
        let artistCountry = await apiOrchestrator.getArtistRegion(
            normalizedArtist: normalizedArtist
        )
        let scoringAlbumTracks = ignoreLocalAlbumYears ? [] : albumTracks
        let determination = yearDeterminator.determineYear(
            candidates: apiCandidates,
            track: track,
            albumTracks: scoringAlbumTracks,
            currentYear: track.year,
            artistActivityPeriod: artistActivityPeriod,
            artistCountry: artistCountry,
            albumTypeInfo: albumTypeInfo,
            queryAlbum: queryAlbum
        )
        return (determination.yearResult, determination.source.rawValue.capitalized)
    }

    private func yearChangeFromAPIDetermination(
        track: Track,
        albumTracks: [Track],
        apiDetermination: (yearResult: YearResult, sourceLabel: String),
        releaseYearConflict: ReleaseYearConflict?
    ) async -> ProposedChange? {
        guard let year = apiDetermination.yearResult.year else {
            return nil
        }
        if year == track.year {
            await markImplausibleYear(
                track: track,
                year: year,
                yearResult: apiDetermination.yearResult
            )
            return nil
        }
        guard Double(apiDetermination.yearResult.confidence) >= runtimeConfiguration.minimumYearUpdateConfidence else {
            return nil
        }
        if !apiDetermination.yearResult.isDefinitive,
           let releaseYearChange = await yearChangeFromFreshReleaseYear(
               track: track,
               albumTracks: albumTracks,
               staleAPIYear: year,
               apiDetermination: apiDetermination
           ) {
            return releaseYearChange
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
            let identity = track.albumIdentity
            await cache.storeAlbumYear(
                artist: identity.artist,
                album: identity.album,
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

    private func yearChangeFromFreshReleaseYear(
        track: Track,
        albumTracks: [Track],
        staleAPIYear: Int,
        apiDetermination: (yearResult: YearResult, sourceLabel: String)
    ) async -> ProposedChange? {
        let contextTracks = albumTracks.isEmpty ? [track] : albumTracks
        guard let releaseYear = releaseYearSignal(for: track, contextTracks: contextTracks) else {
            return nil
        }
        let currentYear = Calendar.current.component(.year, from: Date())
        guard releaseYear == currentYear, staleAPIYear < releaseYear else {
            return nil
        }

        let identity = track.albumIdentity
        await pendingVerificationService?.markForVerification(
            artist: identity.artist,
            album: identity.album,
            reason: "stale_api_data_for_fresh_album",
            metadata: [
                "current_year": String(currentYear),
                "proposed_year": String(staleAPIYear),
                "release_year": String(releaseYear),
            ],
            recheckDays: nil
        )

        return ProposedChange(
            track: track,
            changeType: .yearUpdate,
            oldValue: track.year.map(String.init),
            newValue: String(releaseYear),
            confidence: apiDetermination.yearResult.confidence,
            source: "Release Year"
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

    private func yearChange(
        track: Track,
        determination: YearDeterminationResult
    ) -> ProposedChange? {
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
              let consensus = yearDeterminator.validator.getConsensusReleaseYear(tracks: tracks),
              case .valid = yearDeterminator.validator.validate(year: consensus)
        else {
            return nil
        }
        return consensus
    }
}
