// YearDetermination.swift — Year update decision flow

import Core
import Foundation

struct YearDecisionContext {
    let releaseYearConflict: ReleaseYearConflict?
    let hasAmbiguousReleaseYearSignal: Bool
    let missingYearThreshold: Double
    let cacheTrustThreshold: Int
    let candidateYearValidator: YearValidator
    let decisionDate: Date
}

private struct YearLookupInput {
    let track: Track
    let safetyTrack: Track
    let albumTracks: [Track]
    let forceLookup: Bool
    let albumType: AlbumTypeInfo
    let queryAlbum: String
    let missingYearThreshold: Double
    let runScope: YearRunScope?
}

private struct YearAPIRequest {
    let track: Track
    let albumTracks: [Track]
    let albumType: AlbumTypeInfo
    let queryAlbum: String
    let referenceYear: Int?
    let ignoresLocalYears: Bool
    let decisionDate: Date
}

private struct YearEffectInput {
    let track: Track
    let albumTracks: [Track]
    let decision: APIYearDecision
    let context: YearDecisionContext
    let appliesAlbumEffects: Bool
    let requiresReleaseYearMatch: Bool
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
            albumTypeInfo: albumTypeInfo,
            missingYearThreshold: runtimeConfiguration.missingYearThreshold
        )
    }

    func determineYearChange(
        track: Track,
        safetyTrack: Track? = nil,
        albumTracks: [Track],
        forceYearLookup: Bool,
        albumTypeInfo: AlbumTypeInfo,
        queryAlbum: String? = nil,
        missingYearThreshold: Double,
        yearRunScope: YearRunScope? = nil
    ) async throws -> ProposedChange? {
        try await determineYearChange(
            YearLookupInput(
                track: track,
                safetyTrack: safetyTrack ?? track,
                albumTracks: albumTracks,
                forceLookup: forceYearLookup,
                albumType: albumTypeInfo,
                queryAlbum: queryAlbum ?? track.album,
                missingYearThreshold: missingYearThreshold,
                runScope: yearRunScope
            )
        )
    }

    private func determineYearChange(_ input: YearLookupInput) async throws -> ProposedChange? {
        if await shouldSkipYearPreflight(
            track: input.safetyTrack,
            albumTracks: input.albumTracks,
            forceYearLookup: input.forceLookup,
            yearRunScope: input.runScope
        ) {
            return nil
        }
        let context = decisionContext(for: input)
        if let runDecision = await input.runScope?.decision(for: input.safetyTrack) {
            return await yearChange(
                from:
                YearEffectInput(
                    track: input.track,
                    albumTracks: input.albumTracks,
                    decision: runDecision,
                    context: context,
                    appliesAlbumEffects: false,
                    requiresReleaseYearMatch: input.forceLookup
                )
            )
        }
        switch await yearShortcutDecision(
            track: input.track,
            albumTracks: input.albumTracks,
            forceYearLookup: input.forceLookup,
            context: context
        ) {
        case .continueToAPI:
            break
        case .skip:
            return nil
        case let .change(change):
            return change
        }
        let apiDetermination = try await apiYearDecision(apiRequest(for: input, context: context))
        let resolved = await resolveRunDecision(apiDetermination, for: input.safetyTrack, in: input.runScope)
        return await yearChange(
            from:
            YearEffectInput(
                track: input.track,
                albumTracks: input.albumTracks,
                decision: resolved.decision,
                context: context,
                appliesAlbumEffects: resolved.appliesAlbumEffects,
                requiresReleaseYearMatch: input.forceLookup
            )
        )
    }

    private func decisionContext(for input: YearLookupInput) -> YearDecisionContext {
        YearDecisionContext(
            releaseYearConflict: releaseYearConflict(
                for: input.track,
                albumTracks: input.albumTracks
            ),
            hasAmbiguousReleaseYearSignal: hasAmbiguousReleaseYearSignal(
                for: input.track,
                albumTracks: input.albumTracks
            ),
            missingYearThreshold: input.missingYearThreshold,
            cacheTrustThreshold: runtimeConfiguration.cacheTrustThreshold,
            candidateYearValidator: yearDeterminator.validator,
            decisionDate: decisionDate()
        )
    }

    private func apiRequest(for input: YearLookupInput, context: YearDecisionContext) -> YearAPIRequest {
        YearAPIRequest(
            track: input.track,
            albumTracks: input.albumTracks,
            albumType: input.albumType,
            queryAlbum: input.queryAlbum,
            referenceYear: albumReferenceYear(
                track: input.track,
                albumTracks: input.albumTracks,
                context: context
            ),
            ignoresLocalYears: input.forceLookup || context.releaseYearConflict != nil
                || context.hasAmbiguousReleaseYearSignal,
            decisionDate: context.decisionDate
        )
    }

    private func resolveRunDecision(
        _ decision: APIYearDecision,
        for track: Track,
        in scope: YearRunScope?
    ) async -> (decision: APIYearDecision, appliesAlbumEffects: Bool) {
        guard let scope else { return (decision, true) }
        return await scope.resolve(decision, for: track)
    }

    private func shouldSkipYearPreflight(
        track: Track,
        albumTracks: [Track],
        forceYearLookup: Bool,
        yearRunScope: YearRunScope?
    ) async -> Bool {
        if let issue = yearDeterminator.yearSafetyIssue(
            track: track,
            albumTracks: albumTracks
        ) {
            if await yearRunScope?.recordSafetyIssue(for: track) != false {
                await markYearSafetyIssue(issue, track: track, albumTracks: albumTracks)
            }
            return true
        }

        guard !forceYearLookup else { return false }
        if isAlbumAlreadyProcessedByMGU(track: track, albumTracks: albumTracks) {
            return true
        }
        return await shouldSkipRecentFallbackRejection(track: track)
    }

    private func markYearSafetyIssue(
        _ issue: YearSafetyIssue,
        track: Track,
        albumTracks: [Track]
    ) async {
        let reason: PendingAlbumReason
        let metadata: [String: String]
        let recheckDays: Int?

        switch issue {
        case let .suspiciousAlbum(uniqueYearCount, albumNameLength):
            reason = .suspiciousAlbum
            metadata = [
                "album_name_length": String(albumNameLength),
                "unique_years": String(uniqueYearCount),
            ]
            recheckDays = nil
        case let .farFutureYear(year):
            reason = .prerelease
            metadata = [
                "expected_year": String(year),
                "track_count": String(albumContextTracks(track: track, albumTracks: albumTracks).count),
            ]
            recheckDays = runtimeConfiguration.prereleaseRecheckDays
        }

        await markPendingAlbum(
            track: track,
            reason: reason,
            metadata: metadata,
            recheckDays: recheckDays
        )
    }

    private func yearShortcutDecision(
        track: Track,
        albumTracks: [Track],
        forceYearLookup: Bool,
        context: YearDecisionContext
    ) async -> YearShortcutDecision {
        guard !forceYearLookup else { return .continueToAPI }

        if let dominant = yearDeterminator.dominantDetermination(
            albumTracks: albumTracks,
            candidateCount: 0
        ) {
            if let change = yearChange(
                track: track,
                determination: dominant,
                missingYearThreshold: context.missingYearThreshold
            ) {
                return .change(change)
            }
            let contextTracks = albumContextTracks(track: track, albumTracks: albumTracks)
            if let dominantYear = dominant.yearResult.year,
               contextTracks.count > 1,
               context.releaseYearConflict == nil,
               !context.hasAmbiguousReleaseYearSignal,
               !contextTracks.contains(where: { $0.yearSetByMGU != nil }),
               !shouldVerifyYear(
                   dominantYear,
                   tracks: contextTracks,
                   decisionDate: context.decisionDate
               ),
               dominantYear == track.year {
                return .skip
            }
        }

        let cachedAlbumYear = await cachedAlbumYear(for: track, context: context)
        if let decision = cachedDecision(
            track: track,
            albumTracks: albumTracks,
            entry: cachedAlbumYear,
            context: context
        ) {
            return decision
        }

        if context.releaseYearConflict == nil,
           !context.hasAmbiguousReleaseYearSignal,
           hasStableYear(
               track: track,
               albumTracks: albumTracks,
               entry: cachedAlbumYear,
               context: context
           ) {
            return .skip
        }

        if context.releaseYearConflict == nil,
           let decision = await consensusDecision(
               track: track,
               albumTracks: albumTracks,
               cachedEntry: cachedAlbumYear,
               context: context
           ) {
            return decision
        }

        return .continueToAPI
    }

    private func cachedAlbumYear(for track: Track, context: YearDecisionContext) async -> AlbumCacheEntry? {
        var firstWeakEntry: AlbumCacheEntry?
        for identity in AlbumIdentity.lookupCandidates(for: track) {
            guard let entry = await cache.getAlbumYear(artist: identity.artist, album: identity.album) else {
                continue
            }
            if isTrustedCacheEntry(entry, context: context) {
                return entry
            }
            firstWeakEntry = firstWeakEntry ?? entry
        }
        return firstWeakEntry
    }

    private func cachedDecision(
        track: Track,
        albumTracks: [Track],
        entry: AlbumCacheEntry?,
        context: YearDecisionContext
    ) -> YearShortcutDecision? {
        let isTrusted = isTrustedCacheEntry(entry, context: context)
        if context.releaseYearConflict == nil,
           !context.hasAmbiguousReleaseYearSignal || isTrusted,
           hasCachedYearMatch(
               track: track,
               albumTracks: albumTracks,
               entry: entry,
               context: context
           ) {
            return .skip
        }

        guard isTrusted else { return nil }
        if let cachedChange = yearChangeFromCached(
            track: track,
            entry: entry,
            missingYearThreshold: context.missingYearThreshold,
            requiredYear: context.releaseYearConflict?.verificationYear
        ) {
            return .change(cachedChange)
        }
        return nil
    }

    private func isTrustedCacheEntry(
        _ entry: AlbumCacheEntry?,
        context: YearDecisionContext
    ) -> Bool {
        guard let entry,
              let year = entry.year,
              context.candidateYearValidator.acceptsCandidateYear(year, at: context.decisionDate)
        else {
            return false
        }
        return entry.confidence >= context.cacheTrustThreshold
    }

    private func consensusDecision(
        track: Track,
        albumTracks: [Track],
        cachedEntry: AlbumCacheEntry?,
        context: YearDecisionContext
    ) async -> YearShortcutDecision? {
        guard let consensus = yearDeterminator.consensusDetermination(
            albumTracks: albumTracks,
            candidateCount: 0
        ), let year = consensus.yearResult.year
        else {
            return nil
        }

        if !isTrustedCacheEntry(cachedEntry, context: context)
            || consensus.yearResult.confidence >= (cachedEntry?.confidence ?? 0) {
            let identity = track.albumIdentity
            await cache.storeAlbumYear(
                artist: identity.artist,
                album: identity.album,
                year: year,
                confidence: consensus.yearResult.confidence
            )
        }

        if let change = yearChange(
            track: track,
            determination: consensus,
            missingYearThreshold: context.missingYearThreshold
        ) {
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

    private func apiYearDecision(_ request: YearAPIRequest) async throws -> APIYearDecision {
        let earliestTrackAddedYear = earliestAddedYear(request.albumTracks)
        let identity = AlbumIdentity(
            artist: AlbumIdentity.groupingArtist(for: request.track),
            album: request.queryAlbum
        )
        let apiCandidates = await apiOrchestrator.getReleaseCandidates(
            artist: identity.artist,
            album: identity.album,
            currentLibraryYear: request.referenceYear,
            earliestTrackAddedYear: earliestTrackAddedYear
        )
        try Task.checkCancellation()
        guard !apiCandidates.isEmpty else {
            return try await legacyYearDecision(
                request,
                identity: identity,
                earliestTrackAddedYear: earliestTrackAddedYear
            )
        }
        let normalizedArtist = normalizeForMatching(identity.artist)
        let evidence = try await artistYearEvidence(normalizedArtist: normalizedArtist, track: request.track)
        let determination = yearDeterminator.determineYear(
            candidates: apiCandidates,
            track: request.track,
            albumTracks: request.albumTracks,
            currentYear: request.referenceYear,
            artistActivityPeriod: evidence.activityPeriod,
            artistStartYear: evidence.startYear,
            artistCountry: evidence.country,
            albumTypeInfo: request.albumType,
            verificationAttempts: evidence.verificationAttempts,
            queryAlbum: request.queryAlbum,
            usesLocalEvidence: !request.ignoresLocalYears,
            decisionDate: request.decisionDate
        )
        return APIYearDecision(
            determination: determination,
            sourceLabel: sourceLabel(for: determination),
            usesLegacyResult: false
        )
    }

    private func legacyYearDecision(
        _ request: YearAPIRequest,
        identity: AlbumIdentity,
        earliestTrackAddedYear: Int?
    ) async throws -> APIYearDecision {
        let lookup = await apiOrchestrator.getAlbumYearLookup(
            artist: identity.artist,
            album: identity.album,
            currentLibraryYear: request.referenceYear,
            earliestTrackAddedYear: earliestTrackAddedYear
        )
        try Task.checkCancellation()
        guard lookup.didAttemptLookup else {
            return APIYearDecision(
                determination: YearDeterminationResult(yearResult: lookup.result, source: .api),
                sourceLabel: apiSourceLabel(for: lookup.result),
                usesLegacyResult: true
            )
        }
        let result = lookup.providerResult
        let normalizedArtist = normalizeForMatching(identity.artist)
        let evidence = try await artistYearEvidence(normalizedArtist: normalizedArtist, track: request.track)
        let determination = yearDeterminator.applyFallback(FallbackContext(
            scoredReleases: [],
            existingYear: request.referenceYear,
            track: request.track,
            albumTracks: request.albumTracks,
            isDefinitive: result.isDefinitive,
            bestScore: result.confidence,
            bestYear: result.year,
            albumTypeInfo: request.albumType,
            verificationAttempts: evidence.verificationAttempts,
            artistStartYear: evidence.startYear,
            decisionYear: Self.utcYear(at: request.decisionDate),
            yearScores: result.yearScores
        ))
        let resolvedSource = determination.source == .api
            ? apiSourceLabel(for: result)
            : sourceLabel(for: determination)
        return APIYearDecision(
            determination: determination,
            sourceLabel: resolvedSource,
            usesLegacyResult: true
        )
    }

    private func yearChange(from input: YearEffectInput) async -> ProposedChange? {
        if input.appliesAlbumEffects {
            await applyVerificationMutations(
                input.decision.determination.verificationMutations,
                track: input.track
            )
        }
        let result = input.decision.determination.yearResult
        guard let year = result.year else { return nil }
        if input.decision.usesLegacyResult {
            return await legacyYearChange(input, year: year, result: result)
        }
        if input.requiresReleaseYearMatch,
           let conflict = input.context.releaseYearConflict,
           conflict.verificationYear != year {
            return nil
        }
        await cacheYear(
            track: input.track,
            year: year,
            confidence: result.confidence,
            appliesAlbumEffects: input.appliesAlbumEffects
        )
        guard YearConfidencePolicy.allows(
            existingYear: input.track.year,
            confidence: result.confidence,
            threshold: input.context.missingYearThreshold
        ), year != input.track.year else { return nil }
        return yearProposal(input.track, year: year, result: result, source: input.decision.sourceLabel)
    }

    private func legacyYearChange(
        _ input: YearEffectInput,
        year: Int,
        result: YearResult
    ) async -> ProposedChange? {
        if year == input.track.year {
            if input.appliesAlbumEffects {
                await markImplausibleYear(track: input.track, year: year, yearResult: result)
                await cacheYear(
                    track: input.track,
                    year: year,
                    confidence: result.confidence,
                    appliesAlbumEffects: true
                )
            }
            return nil
        }
        guard YearConfidencePolicy.allows(
            existingYear: input.track.year,
            confidence: result.confidence,
            threshold: input.context.missingYearThreshold
        ) else { return nil }
        if !result.isDefinitive,
           let releaseYearChange = await freshYearChange(input, staleYear: year) {
            return releaseYearChange
        }
        if let conflict = input.context.releaseYearConflict, conflict.verificationYear != year {
            return nil
        }
        if await shouldPreserveExistingYearForArtistStart(
            track: input.track,
            proposedYear: year,
            yearResult: result
        ) {
            return nil
        }
        await cacheYear(
            track: input.track,
            year: year,
            confidence: result.confidence,
            appliesAlbumEffects: input.appliesAlbumEffects
        )
        return yearProposal(input.track, year: year, result: result, source: input.decision.sourceLabel)
    }

    private func freshYearChange(
        _ input: YearEffectInput,
        staleYear: Int
    ) async -> ProposedChange? {
        let tracks = input.albumTracks.isEmpty ? [input.track] : input.albumTracks
        guard let releaseYear = releaseYearSignal(for: input.track, contextTracks: tracks) else {
            return nil
        }
        let currentYear = Self.utcYear(at: input.context.decisionDate)
        guard releaseYear == currentYear, staleYear < releaseYear else { return nil }

        if input.appliesAlbumEffects {
            let identity = input.track.albumIdentity
            await pendingVerificationService?.markForVerification(
                artist: identity.artist,
                album: identity.album,
                reason: "stale_api_data_for_fresh_album",
                metadata: [
                    "current_year": String(currentYear),
                    "proposed_year": String(staleYear),
                    "release_year": String(releaseYear),
                ],
                recheckDays: nil
            )
            await cacheYear(
                track: input.track,
                year: releaseYear,
                confidence: input.decision.determination.yearResult.confidence,
                appliesAlbumEffects: true
            )
        }
        return yearProposal(
            input.track,
            year: releaseYear,
            result: input.decision.determination.yearResult,
            source: "Release Year"
        )
    }

    private func yearProposal(
        _ track: Track,
        year: Int,
        result: YearResult,
        source: String
    ) -> ProposedChange {
        ProposedChange(
            track: track,
            changeType: .yearUpdate,
            oldValue: track.year.map(String.init),
            newValue: String(year),
            confidence: result.confidence,
            source: source
        )
    }

    private func cacheYear(
        track: Track,
        year: Int,
        confidence: Int,
        appliesAlbumEffects: Bool
    ) async {
        guard appliesAlbumEffects,
              confidence >= runtimeConfiguration.minimumConfidenceToCache
        else {
            return
        }
        let identity = track.albumIdentity
        await cache.storeAlbumYear(
            artist: identity.artist,
            album: identity.album,
            year: year,
            confidence: confidence
        )
    }

    private func applyVerificationMutations(
        _ mutations: [YearVerificationMutation],
        track: Track
    ) async {
        guard let pendingVerificationService else { return }
        let identity = track.albumIdentity
        for mutation in mutations {
            switch mutation {
            case let .mark(reason, metadata):
                await pendingVerificationService.markForVerification(
                    artist: identity.artist,
                    album: identity.album,
                    reason: reason.rawValue,
                    metadata: metadata,
                    recheckDays: nil
                )
            case .remove:
                await pendingVerificationService.removeFromPending(
                    artist: identity.artist,
                    album: identity.album
                )
            }
        }
    }

    private func sourceLabel(for determination: YearDeterminationResult) -> String {
        switch determination.source {
        case .api: "Api"
        case .consensus: "Release Year"
        case .dominant: "Dominant"
        case .fallback: "Fallback"
        case .library: "Library"
        case .manual: "Manual"
        }
    }

    private func apiSourceLabel(for result: YearResult) -> String {
        result.isDefinitive ? "Definitive" : "API"
    }

    private func yearChangeFromCached(
        track: Track,
        entry: AlbumCacheEntry?,
        missingYearThreshold: Double,
        requiredYear: Int? = nil
    ) -> ProposedChange? {
        guard let entry,
              let year = entry.year,
              year != track.year,
              YearConfidencePolicy.allows(
                  existingYear: track.year,
                  confidence: entry.confidence,
                  threshold: missingYearThreshold
              )
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
        determination: YearDeterminationResult,
        missingYearThreshold: Double
    ) -> ProposedChange? {
        let yearResult = determination.yearResult

        guard YearConfidencePolicy.allows(
            existingYear: track.year,
            confidence: yearResult.confidence,
            threshold: missingYearThreshold
        ),
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
}
