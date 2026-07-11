// swiftlint:disable file_length

import Core
import Services

struct PendingEntryOutcome {
    var completed: [ChangeLogEntry] = []
    var successfulTrackIDs: [String] = []
    var failedTrackIDs: [String] = []
    var errorDescriptions: [String] = []
    var processedCount = 0
    var resolvedIdentityKeys: Set<String> = []
    var handledIdentityKeys: Set<String> = []

    var isEmpty: Bool {
        completed.isEmpty && successfulTrackIDs.isEmpty && failedTrackIDs.isEmpty && errorDescriptions
            .isEmpty && processedCount == 0
    }
}

private struct PendingVerificationCancellation: Error {
    let outcome: PendingEntryOutcome
}

private struct PendingVerificationFailure: Error {
    let outcome: PendingEntryOutcome
    let underlyingError: any Error
}

private struct PendingVerificationTrackContext {
    var tracks: [Track]
    var missingTracks: [Track]
}

#if DEBUG
enum PendingScopeRefreshInstrumentation {
    @TaskLocal static var onRefreshCompleted: (@Sendable () async -> Void)?
}
#endif

extension WorkflowViewModel {
    func startPendingVerification(tracks: [Track]) {
        guard let pendingVerificationService else {
            invalidatePendingVerificationRefreshes()
            pendingVerificationReportSummary = nil
            phase = .error("Pending verification service is unavailable")
            return
        }

        let refreshGeneration = preparePendingVerificationRun()

        processingTask = Task {
            guard await !stopForRecoveryHold() else { return }
            await runPendingVerification(
                tracks: tracks,
                pendingVerificationService: pendingVerificationService,
                refreshGeneration: refreshGeneration
            )
        }
    }

    func refreshPendingScope(tracks: [Track]) {
        let refreshGeneration = invalidatePendingVerificationRefreshes()
        Task { [refreshGeneration, tracks] in
            #if DEBUG
            defer {
                if let onRefreshCompleted = PendingScopeRefreshInstrumentation.onRefreshCompleted {
                    Task {
                        await onRefreshCompleted()
                    }
                }
            }
            #endif
            let snapshot = await pendingVerificationSnapshot()
            guard isCurrentPendingVerificationRefresh(refreshGeneration) else { return }
            updatePendingScope(snapshot: snapshot, tracks: tracks)
            await refreshPendingVerificationReportSummary(
                snapshot: snapshot,
                refreshGeneration: refreshGeneration
            )
        }
    }

    func tracksForCurrentMode(_ tracks: [Track]) -> [Track] {
        switch mode {
        case .smartFilter:
            applySmartFilter(to: tracks)
        case .pendingVerification:
            []
        case .releaseYearRestore:
            Self.tracksNeedingReleaseYearRestore(
                tracks,
                threshold: releaseYearRestoreThreshold
            )
        case .selectedTracks, .fullLibrary:
            tracks
        }
    }

    @discardableResult
    func invalidatePendingVerificationRefreshes() -> Int {
        pendingVerificationRefreshGeneration += 1
        return pendingVerificationRefreshGeneration
    }

    func isCurrentPendingVerificationRefresh(_ refreshGeneration: Int) -> Bool {
        mode == .pendingVerification && refreshGeneration == pendingVerificationRefreshGeneration
    }

    private func preparePendingVerificationRun() -> Int {
        let refreshGeneration = invalidatePendingVerificationRefreshes()
        phase = .scanning
        processedCount = 0
        failedCount = 0
        currentTrackID = nil
        proposedChanges = []
        completedEntries = []
        result = nil
        dryRunReport = nil
        maintenancePreflightResult = nil
        pendingVerificationReportSummary = nil
        return refreshGeneration
    }

    private func runPendingVerification(
        tracks: [Track],
        pendingVerificationService: any PendingVerificationService,
        refreshGeneration: Int
    ) async {
        do {
            let report = await pendingVerificationReport()
            let snapshot = report.snapshot
            let dueEntries = snapshot.due
            let trackContext = await pendingVerificationTrackContext(from: tracks)
            guard isCurrentPendingVerificationRefresh(refreshGeneration) else { return }
            updatePendingScope(snapshot: snapshot, tracks: trackContext.tracks)
            guard applyPendingVerificationReportSummary(
                snapshot: snapshot,
                problematicDetails: report.problematicDetails,
                refreshGeneration: refreshGeneration
            ) else { return }
            preparePendingVerificationScope(tracks: trackContext.tracks, dueEntries: dueEntries)
            let runOutcome = try await batchProcessor.performRecoverableWrite { @MainActor [self] in
                try await performPendingVerification(
                    dueEntries: dueEntries,
                    trackContext: trackContext,
                    pendingVerificationService: pendingVerificationService
                )
            }
            let finalRefreshGeneration = invalidatePendingVerificationRefreshes()
            await refreshPendingVerificationReportSummary(
                refreshGeneration: finalRefreshGeneration,
                outcome: runOutcome
            )
            guard isCurrentPendingVerificationRefresh(finalRefreshGeneration) else { return }
            finishPendingVerification(runOutcome)
        } catch let cancellation as PendingVerificationCancellation {
            finishCancelledPendingVerification(outcome: cancellation.outcome)
        } catch let error as AppleScriptOutcomeError {
            await handleUnknownOutcome(error)
        } catch let failure as PendingVerificationFailure {
            finishFailedPendingVerification(outcome: failure.outcome, error: failure.underlyingError)
        } catch is CancellationError {
            finishCancelledPendingVerification(outcome: PendingEntryOutcome())
        } catch {
            finishFailedPendingVerification(outcome: PendingEntryOutcome(), error: error)
        }
    }

    func runPendingVerificationBeforeBatchIfDue(
        preflightResult: MaintenancePreflightResult?,
        tracks: [Track]
    ) async -> PendingEntryOutcome {
        guard shouldRunBatchProcessing,
              preflightResult?.isPendingVerificationDue == true,
              let pendingVerificationService
        else {
            return PendingEntryOutcome()
        }

        do {
            let report = await pendingVerificationReport()
            let snapshot = report.snapshot
            let dueEntries = snapshot.due

            updatePendingVerificationReportSummary(
                snapshot: snapshot,
                problematicDetails: report.problematicDetails
            )
            guard !dueEntries.isEmpty else { return PendingEntryOutcome() }

            let pendingScopeTracks = Self.pendingMutationPreparationTracks(
                tracks,
                entries: dueEntries
            )
            guard await prepareWriteMetadata(for: pendingScopeTracks) else {
                return PendingEntryOutcome()
            }

            let trackContext = await pendingVerificationTrackContext(from: pendingScopeTracks)
            preparePendingVerificationScope(tracks: trackContext.tracks, dueEntries: dueEntries)
            let outcome = try await batchProcessor.performRecoverableWrite { @MainActor [self] in
                try await performPendingVerification(
                    dueEntries: dueEntries,
                    trackContext: trackContext,
                    pendingVerificationService: pendingVerificationService
                )
            }
            let finalSnapshot = await pendingVerificationSnapshot()
            await refreshPendingVerificationReportSummary(snapshot: finalSnapshot, outcome: outcome)
            failedCount = outcome.failedTrackIDs.count
            return outcome
        } catch let cancellation as PendingVerificationCancellation {
            finishCancelledPendingVerification(outcome: cancellation.outcome)
            return cancellation.outcome
        } catch let error as AppleScriptOutcomeError {
            await handleUnknownOutcome(error)
            return PendingEntryOutcome()
        } catch let failure as PendingVerificationFailure {
            finishFailedPendingVerification(outcome: failure.outcome, error: failure.underlyingError)
            return failure.outcome
        } catch is CancellationError {
            let outcome = PendingEntryOutcome()
            finishCancelledPendingVerification(outcome: outcome)
            return outcome
        } catch {
            finishFailedPendingVerification(outcome: PendingEntryOutcome(), error: error)
            return PendingEntryOutcome()
        }
    }

    private func performPendingVerification(
        dueEntries: [PendingAlbumEntry],
        trackContext: PendingVerificationTrackContext,
        pendingVerificationService: any PendingVerificationService
    ) async throws -> PendingEntryOutcome {
        let albumGroups = Self.groupTracksByAlbum(trackContext.tracks)
        var runOutcome = PendingEntryOutcome()
        var handledPendingKeys: Set<String> = []

        for (index, entry) in dueEntries.enumerated() {
            do {
                try Task.checkCancellation()
                updatePendingProgress(entry: entry, index: index, total: dueEntries.count)

                let entryKeys = Self.pendingIdentityKeys(for: entry)
                guard entryKeys.isDisjoint(with: handledPendingKeys) else {
                    continue
                }

                let albumTracks = Self.pendingAlbumTracks(for: entry, in: albumGroups)
                let entryOutcome = try await processPendingEntry(
                    entry,
                    albumTracks: albumTracks,
                    albumGroups: albumGroups,
                    missingContextTracks: trackContext.missingTracks,
                    pendingVerificationService: pendingVerificationService
                )
                runOutcome.merge(entryOutcome)
                handledPendingKeys.formUnion(entryOutcome.handledIdentityKeys)
                processedCount += entryOutcome.processedCount
            } catch is CancellationError {
                throw PendingVerificationCancellation(outcome: runOutcome)
            }
        }

        if !dueEntries.isEmpty,
           runOutcome.failedTrackIDs.isEmpty,
           runOutcome.errorDescriptions.isEmpty {
            do {
                try await pendingVerificationService.updateVerificationTimestamp()
            } catch is CancellationError {
                throw PendingVerificationCancellation(outcome: runOutcome)
            } catch {
                throw PendingVerificationFailure(outcome: runOutcome, underlyingError: error)
            }
        }
        return runOutcome
    }

    private func pendingVerificationTrackContext(from tracks: [Track]) async -> PendingVerificationTrackContext {
        let albumTracksByTrackID = await updateCoordinator.albumContextTracksByTrackID(for: tracks)
        var seenTrackIDs: Set<String> = []
        let contextTracks = tracks.flatMap { track in
            albumTracksByTrackID[track.id] ?? []
        }.filter { track in
            seenTrackIDs.insert(track.id).inserted
        }
        let missingTracks = tracks.filter { albumTracksByTrackID[$0.id] == nil }
        return PendingVerificationTrackContext(tracks: contextTracks, missingTracks: missingTracks)
    }

    private func preparePendingTrackStatuses(tracks: [Track], dueEntries: [PendingAlbumEntry]) {
        let scopedTracks = Self.tracksMatchingPendingEntries(tracks, entries: dueEntries)
        trackStatuses = Dictionary(uniqueKeysWithValues: scopedTracks.map { ($0.id, .queued) })
        totalCount = scopedTracks.count
    }

    private func preparePendingVerificationScope(tracks: [Track], dueEntries: [PendingAlbumEntry]) {
        processedCount = 0
        failedCount = 0
        currentTrackID = nil
        preparePendingTrackStatuses(tracks: tracks, dueEntries: dueEntries)
    }

    private func updatePendingProgress(entry: PendingAlbumEntry, index: Int, total: Int) {
        progress = ProgressUpdate(
            phase: .updating,
            current: index + 1,
            total: total,
            message: "\(entry.artist) - \(entry.album)"
        )
    }

    private func finishPendingVerification(_ outcome: PendingEntryOutcome) {
        preservePendingVerificationOutcome(outcome)
        currentTrackID = nil
        phase = .done
        progress = nil
    }

    private func finishCancelledPendingVerification(outcome: PendingEntryOutcome) {
        trackStatuses = [:]
        if outcome.isEmpty {
            clearPendingVerificationOutcome()
        } else {
            preservePendingVerificationOutcome(outcome)
        }
        currentTrackID = nil
        phase = .configure
        progress = nil
    }

    private func finishFailedPendingVerification(outcome: PendingEntryOutcome, error: any Error) {
        if outcome.isEmpty {
            clearPendingVerificationOutcome()
        } else {
            preservePendingVerificationOutcome(outcome)
        }
        currentTrackID = nil
        phase = .error(error.localizedDescription)
        progress = nil
    }

    private func clearPendingVerificationOutcome() {
        completedEntries = []
        result = nil
        processedCount = 0
        failedCount = 0
    }

    private func preservePendingVerificationOutcome(_ outcome: PendingEntryOutcome) {
        restorePreflightStatuses(outcome)
        completedEntries = outcome.completed
        result = BatchUpdateResult(
            entries: outcome.completed,
            failedTrackIDs: outcome.failedTrackIDs,
            errorDescriptions: outcome.errorDescriptions
        )
        processedCount = outcome.processedCount
        failedCount = outcome.failedTrackIDs.count
        totalCount = max(totalCount, outcome.processedCount)
    }

    private func processPendingEntry(
        _ entry: PendingAlbumEntry,
        albumTracks: [Track],
        albumGroups: [String: [Track]],
        missingContextTracks: [Track],
        pendingVerificationService: any PendingVerificationService
    ) async throws -> PendingEntryOutcome {
        let missingEntryTracks = Self.missingContextTracks(
            for: entry,
            albumTracks: albumTracks,
            missingTracks: missingContextTracks
        )
        guard missingEntryTracks.isEmpty else {
            let errorDescription = "Missing AppleScript metadata for \(entry.artist) - \(entry.album)"
            let failedTracks = Self.uniqueTracks(albumTracks + missingEntryTracks)
            markPendingAlbumTracks(failedTracks, as: .failed(errorDescription))
            totalCount = max(totalCount, trackStatuses.count)
            return PendingEntryOutcome(
                failedTrackIDs: failedTracks.map(\.id),
                errorDescriptions: Array(repeating: errorDescription, count: failedTracks.count),
                processedCount: failedTracks.count,
                handledIdentityKeys: Self.pendingHandledIdentityKeys(
                    entry: entry,
                    albumTracks: albumTracks,
                    albumGroups: albumGroups
                )
            )
        }

        guard !albumTracks.isEmpty else {
            return PendingEntryOutcome(
                failedTrackIDs: [entry.id],
                errorDescriptions: ["No local tracks found for \(entry.artist) - \(entry.album)"],
                handledIdentityKeys: Self.pendingIdentityKeys(for: entry)
            )
        }

        markPendingAlbumTracks(albumTracks, as: .writing)

        do {
            let verification = try await updateCoordinator.verifyPendingAlbum(
                entry,
                albumTracks: albumTracks
            )
            return await handlePendingVerification(
                verification,
                entry: entry,
                albumTracks: albumTracks,
                albumGroups: albumGroups,
                pendingVerificationService: pendingVerificationService
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AppleScriptOutcomeError {
            throw error
        } catch {
            markPendingAlbumTracks(albumTracks, as: .failed(error.localizedDescription))
            return PendingEntryOutcome(
                failedTrackIDs: albumTracks.map(\.id),
                errorDescriptions: [error.localizedDescription],
                processedCount: albumTracks.count,
                handledIdentityKeys: Self.pendingHandledIdentityKeys(
                    entry: entry,
                    albumTracks: albumTracks,
                    albumGroups: albumGroups
                )
            )
        }
    }

    private func pendingVerificationSnapshot() async -> (all: [PendingAlbumEntry], due: [PendingAlbumEntry]) {
        guard let pendingVerificationService else { return ([], []) }
        return await pendingVerificationService.getPendingVerificationSnapshot()
    }

    private func problematicPendingAlbumDetails() async -> [UpdateRunPendingVerificationDetail] {
        guard let pendingVerificationService else { return [] }
        return await pendingVerificationService
            .getProblematicPendingAlbums(minAttempts: resolvedProblematicAlbumReportMinAttempts)
            .map(UpdateRunPendingVerificationDetail.init)
    }

    private func pendingVerificationReport() async -> (
        snapshot: (all: [PendingAlbumEntry], due: [PendingAlbumEntry]),
        problematicDetails: [UpdateRunPendingVerificationDetail]
    ) {
        let snapshot = await pendingVerificationSnapshot()
        let problematicDetails = await problematicPendingAlbumDetails()
        return (snapshot, problematicDetails)
    }

    private func refreshPendingVerificationReportSummary(
        snapshot: (all: [PendingAlbumEntry], due: [PendingAlbumEntry]),
        outcome: PendingEntryOutcome? = nil
    ) async {
        let problematicDetails = await problematicPendingAlbumDetails()
        updatePendingVerificationReportSummary(
            snapshot: snapshot,
            problematicDetails: problematicDetails,
            outcome: outcome
        )
    }

    private var resolvedProblematicAlbumReportMinAttempts: Int {
        max(1, problematicAlbumReportMinAttempts())
    }

    private func updatePendingScope(
        snapshot: (all: [PendingAlbumEntry], due: [PendingAlbumEntry]),
        tracks: [Track]
    ) {
        pendingAlbumCount = snapshot.all.count
        pendingDueAlbumCount = snapshot.due.count
        pendingSkippedAlbumCount = max(0, snapshot.all.count - snapshot.due.count)

        let scopedTracks = Self.tracksMatchingPendingEntries(tracks, entries: snapshot.due)
        scopeTrackCount = scopedTracks.count
        scopeArtistCount = Set(scopedTracks.map(\.artist)).count
    }

    private func updatePendingVerificationReportSummary(
        snapshot: (all: [PendingAlbumEntry], due: [PendingAlbumEntry]),
        problematicDetails: [UpdateRunPendingVerificationDetail],
        outcome: PendingEntryOutcome? = nil
    ) {
        guard !snapshot.all.isEmpty else {
            pendingVerificationReportSummary = nil
            return
        }

        let skippedByInterval = max(0, snapshot.all.count - snapshot.due.count)
        let verifiedCount = outcome?.resolvedIdentityKeys.count ?? 0

        pendingVerificationReportSummary = UpdateRunPendingVerificationSummary(
            total: snapshot.all.count,
            due: snapshot.due.count,
            problematic: problematicDetails.count,
            skippedByInterval: skippedByInterval,
            verified: verifiedCount,
            problematicDetails: problematicDetails
        )
    }

    @discardableResult
    private func applyPendingVerificationReportSummary(
        snapshot: (all: [PendingAlbumEntry], due: [PendingAlbumEntry]),
        problematicDetails: [UpdateRunPendingVerificationDetail],
        refreshGeneration: Int,
        outcome: PendingEntryOutcome? = nil
    ) -> Bool {
        guard isCurrentPendingVerificationRefresh(refreshGeneration) else { return false }
        updatePendingVerificationReportSummary(
            snapshot: snapshot,
            problematicDetails: problematicDetails,
            outcome: outcome
        )
        return true
    }

    private func refreshPendingVerificationReportSummary(
        refreshGeneration: Int,
        outcome: PendingEntryOutcome? = nil
    ) async {
        let snapshot = await pendingVerificationSnapshot()
        await refreshPendingVerificationReportSummary(
            snapshot: snapshot,
            refreshGeneration: refreshGeneration,
            outcome: outcome
        )
    }

    private func refreshPendingVerificationReportSummary(
        snapshot: (all: [PendingAlbumEntry], due: [PendingAlbumEntry]),
        refreshGeneration: Int,
        outcome: PendingEntryOutcome? = nil
    ) async {
        let problematicDetails = await problematicPendingAlbumDetails()
        applyPendingVerificationReportSummary(
            snapshot: snapshot,
            problematicDetails: problematicDetails,
            refreshGeneration: refreshGeneration,
            outcome: outcome
        )
    }

    private func handlePendingVerification(
        _ verification: PendingAlbumVerificationResult,
        entry: PendingAlbumEntry,
        albumTracks: [Track],
        albumGroups: [String: [Track]],
        pendingVerificationService: any PendingVerificationService
    ) async -> PendingEntryOutcome {
        if verification.canClearPendingEntry, !verification.hasFailures {
            let resolvedIdentities = Self.pendingResolvedIdentities(
                entry: entry,
                albumTracks: albumTracks,
                albumGroups: albumGroups
            )
            let resolvedIdentityKeys = Set(resolvedIdentities.map(\.key))
            for identity in resolvedIdentities {
                await pendingVerificationService.removeFromPending(
                    artist: identity.artist,
                    album: identity.album
                )
            }
            markPendingAlbumTracks(albumTracks, as: .done)
            return PendingEntryOutcome(
                completed: verification.entries,
                successfulTrackIDs: albumTracks.map(\.id),
                processedCount: albumTracks.count,
                resolvedIdentityKeys: resolvedIdentityKeys,
                handledIdentityKeys: resolvedIdentityKeys
            )
        } else if verification.didResolveYear {
            markPartiallyVerifiedPendingAlbumTracks(albumTracks, verification: verification)
            return PendingEntryOutcome(
                completed: verification.entries,
                failedTrackIDs: verification.failedTrackIDs,
                errorDescriptions: verification.errorDescriptions,
                processedCount: albumTracks.count,
                handledIdentityKeys: Self.pendingHandledIdentityKeys(
                    entry: entry,
                    albumTracks: albumTracks,
                    albumGroups: albumGroups
                )
            )
        } else {
            markPendingAlbumTracks(albumTracks, as: .failed("No year resolved"))
            return PendingEntryOutcome(
                failedTrackIDs: albumTracks.map(\.id),
                errorDescriptions: ["No year resolved for \(entry.artist) - \(entry.album)"],
                processedCount: albumTracks.count,
                handledIdentityKeys: Self.pendingHandledIdentityKeys(
                    entry: entry,
                    albumTracks: albumTracks,
                    albumGroups: albumGroups
                )
            )
        }
    }

    private func markPartiallyVerifiedPendingAlbumTracks(
        _ albumTracks: [Track],
        verification: PendingAlbumVerificationResult
    ) {
        let changedTrackIDs = Set(verification.entries.map(\.trackID))
        let unchangedTrackIDs = Set(verification.unchangedTrackIDs)
        let failedTrackIDs = Set(verification.failedTrackIDs)
        let errorDescription = verification.errorDescriptions.first ?? "Pending verification write failed"
        let errorDescriptionsByTrackID = Self.errorDescriptionsByTrackID(
            failedTrackIDs: verification.failedTrackIDs,
            errorDescriptions: verification.errorDescriptions,
            fallback: errorDescription
        )

        for track in albumTracks {
            currentTrackID = track.id
            if failedTrackIDs.contains(track.id) {
                trackStatuses[track.id] = .failed(errorDescriptionsByTrackID[track.id] ?? errorDescription)
            } else if changedTrackIDs.contains(track.id)
                || unchangedTrackIDs.contains(track.id)
                || verification.resolvedYear == track.year {
                trackStatuses[track.id] = .done
            }
        }
    }

    private func markPendingAlbumTracks(_ albumTracks: [Track], as status: TrackProcessingStatus) {
        for track in albumTracks {
            currentTrackID = track.id
            trackStatuses[track.id] = status
        }
    }

    static func tracksMatchingPendingEntries(_ tracks: [Track], entries: [PendingAlbumEntry]) -> [Track] {
        let albumGroups = groupTracksByAlbum(tracks)
        var seenTrackIDs: Set<String> = []
        var matchedTracks: [Track] = []
        for entry in entries {
            for track in pendingAlbumTracks(for: entry, in: albumGroups) where seenTrackIDs.insert(track.id).inserted {
                matchedTracks.append(track)
            }
        }
        return sortedForBatchProcessing(matchedTracks)
    }

    private static func pendingMutationPreparationTracks(
        _ tracks: [Track],
        entries: [PendingAlbumEntry]
    ) -> [Track] {
        var seenTrackIDs: Set<String> = []
        var candidateTracks: [Track] = []

        let tracksByAlbumTitle = Dictionary(grouping: tracks) { track in
            normalizeForMatching(track.album)
        }
        for entry in entries {
            let exactMatches = tracksMatchingPendingEntries(tracks, entries: [entry])
            let entryTracks: [Track]
            if exactMatches.isEmpty {
                let albumTitleKey = normalizeForMatching(entry.album)
                if !albumTitleKey.isEmpty {
                    entryTracks = tracksByAlbumTitle[albumTitleKey] ?? []
                } else {
                    entryTracks = []
                }
            } else {
                entryTracks = exactMatches
            }

            for track in sortedForBatchProcessing(entryTracks)
                where seenTrackIDs.insert(track.id).inserted {
                candidateTracks.append(track)
            }
        }

        return sortedForBatchProcessing(candidateTracks)
    }

    static func pendingAlbumTracks(
        for entry: PendingAlbumEntry,
        in albumGroups: [String: [Track]]
    ) -> [Track] {
        matchingPendingAlbumTracks(artist: entry.artist, album: entry.album, albumGroups: albumGroups)
    }

    private static func matchingPendingAlbumTracks(
        artist: String,
        album: String,
        albumGroups: [String: [Track]]
    ) -> [Track] {
        let primaryPendingKey = AlbumIdentity.key(artist: artist, album: album)
        let pendingKeys = Set(AlbumIdentity.lookupKeys(artist: artist, album: album))
        var matchedGroups: [[Track]] = []
        for (groupKey, tracks) in albumGroups {
            let groupMatchesEntry = tracks.contains { track in
                let trackKeys = Set(AlbumIdentity.lookupKeys(for: track))
                return !pendingKeys.isDisjoint(with: trackKeys)
            }
            guard groupKey == primaryPendingKey || groupMatchesEntry else {
                continue
            }
            matchedGroups.append(tracks)
        }

        guard matchedGroups.count == 1, let matchedTracks = matchedGroups.first else {
            return []
        }
        return sortedForBatchProcessing(matchedTracks)
    }

    private static func pendingResolvedIdentities(
        entry: PendingAlbumEntry,
        albumTracks: [Track],
        albumGroups: [String: [Track]]
    ) -> [AlbumIdentity] {
        let albumTrackIDs = Set(albumTracks.map { track in track.id })
        var candidates = pendingRemovalIdentities(entry: entry, albumTracks: albumTracks)
        for track in albumTracks {
            candidates.append(contentsOf: AlbumIdentity.lookupCandidates(for: track))
        }
        var resolvedIdentities: [AlbumIdentity] = []
        var seenKeys: Set<String> = []

        for identity in candidates
            where seenKeys.insert(identity.key).inserted {
            let resolvedTracks = matchingPendingAlbumTracks(
                artist: identity.artist,
                album: identity.album,
                albumGroups: albumGroups
            )
            if Set(resolvedTracks.map { track in track.id }) == albumTrackIDs {
                resolvedIdentities.append(identity)
            }
        }

        return resolvedIdentities
    }

    private static func missingContextTracks(
        for entry: PendingAlbumEntry,
        albumTracks: [Track],
        missingTracks: [Track]
    ) -> [Track] {
        let entryKeys = pendingIdentityKeys(for: entry)
        var matchedTrackKeys: Set<String> = []

        for albumTrack in albumTracks {
            matchedTrackKeys.formUnion(AlbumIdentity.lookupKeys(for: albumTrack))
        }

        var relevantTracks: [Track] = []
        for track in missingTracks {
            let missingTrackKeys = Set(AlbumIdentity.lookupKeys(for: track))
            let matchesEntry = !entryKeys.isDisjoint(with: missingTrackKeys)
            let matchesMatchedTrack = !matchedTrackKeys.isDisjoint(with: missingTrackKeys)

            if matchesEntry || matchesMatchedTrack {
                relevantTracks.append(track)
            }
        }
        return relevantTracks
    }

    private static func pendingHandledIdentityKeys(
        entry: PendingAlbumEntry,
        albumTracks: [Track],
        albumGroups: [String: [Track]]
    ) -> Set<String> {
        let identities = pendingResolvedIdentities(
            entry: entry,
            albumTracks: albumTracks,
            albumGroups: albumGroups
        )
        guard !identities.isEmpty else {
            return pendingIdentityKeys(for: entry)
        }
        return Set(identities.map(\.key))
    }

    private static func pendingIdentityKeys(for entry: PendingAlbumEntry) -> Set<String> {
        Set(AlbumIdentity.lookupKeys(artist: entry.artist, album: entry.album))
    }

    static func pendingRemovalIdentities(entry: PendingAlbumEntry, albumTracks: [Track]) -> [AlbumIdentity] {
        var seenKeys: Set<String> = []
        let candidates = AlbumIdentity.lookupCandidates(artist: entry.artist, album: entry.album)
            + albumTracks.flatMap(pendingTrackRemovalIdentities)
        return candidates.filter { identity in
            seenKeys.insert(identity.key).inserted
        }
    }

    private static func pendingTrackRemovalIdentities(for track: Track) -> [AlbumIdentity] {
        let canonicalIdentity = track.albumIdentity
        return AlbumIdentity.lookupCandidates(for: track).filter { identity in
            let identityKeys = Set(AlbumIdentity.lookupKeys(artist: identity.artist, album: identity.album))
            return identity == canonicalIdentity || identityKeys.contains(canonicalIdentity.key)
        }
    }

    static func groupTracksByAlbum(_ tracks: [Track]) -> [String: [Track]] {
        Dictionary(grouping: tracks) { albumKey(for: $0) }
    }

    static func groupTracksByArtist(_ tracks: [Track]) -> [String: [Track]] {
        Dictionary(grouping: tracks) { artistKey(for: $0) }
    }

    static func sortedForBatchProcessing(_ tracks: [Track]) -> [Track] {
        tracks.sorted { leftTrack, rightTrack in
            batchSortComponents(for: leftTrack).lexicographicallyPrecedes(
                batchSortComponents(for: rightTrack)
            )
        }
    }

    static func albumKey(for track: Track) -> String {
        AlbumIdentity.key(for: track)
    }

    static func albumKey(artist: String, album: String) -> String {
        AlbumIdentity.key(artist: artist, album: album)
    }

    static func artistKey(for track: Track) -> String {
        normalizeForMatching(track.effectiveArtist)
    }

    private static func batchSortComponents(for track: Track) -> [String] {
        [
            track.effectiveArtist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            track.album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            track.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            track.id,
        ]
    }

    static func uniqueTracks(_ tracks: [Track]) -> [Track] {
        var seenTrackIDs: Set<String> = []
        return tracks.filter { track in
            seenTrackIDs.insert(track.id).inserted
        }
    }

    private static func errorDescriptionsByTrackID(
        failedTrackIDs: [String],
        errorDescriptions: [String],
        fallback: String
    ) -> [String: String] {
        var descriptionsByTrackID: [String: String] = [:]
        for (index, trackID) in failedTrackIDs.enumerated() where descriptionsByTrackID[trackID] == nil {
            descriptionsByTrackID[trackID] = errorDescriptions[safe: index] ?? fallback
        }
        return descriptionsByTrackID
    }
}

extension PendingEntryOutcome {
    fileprivate mutating func merge(_ other: PendingEntryOutcome) {
        completed.append(contentsOf: other.completed)
        successfulTrackIDs.append(contentsOf: other.successfulTrackIDs)
        failedTrackIDs.append(contentsOf: other.failedTrackIDs)
        errorDescriptions.append(contentsOf: other.errorDescriptions)
        processedCount += other.processedCount
        resolvedIdentityKeys.formUnion(other.resolvedIdentityKeys)
        handledIdentityKeys.formUnion(other.handledIdentityKeys)
    }
}
