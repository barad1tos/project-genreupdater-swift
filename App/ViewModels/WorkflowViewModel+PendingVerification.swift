// WorkflowViewModel+PendingVerification.swift -- Pending album verification workflow.

import Core
import Services

private struct PendingEntryOutcome {
    var completed: [ChangeLogEntry] = []
    var failedTrackIDs: [String] = []
    var errorDescriptions: [String] = []
    var processedCount = 0
    var resolvedIdentityKeys: Set<String> = []
}

extension WorkflowViewModel {
    func startPendingVerification(tracks: [Track]) {
        guard let pendingVerificationService else {
            phase = .error("Pending verification service is unavailable")
            return
        }

        preparePendingVerificationRun()

        processingTask = Task {
            await runPendingVerification(
                tracks: tracks,
                pendingVerificationService: pendingVerificationService
            )
        }
    }

    func refreshPendingScope(tracks: [Track]) {
        Task {
            let snapshot = await pendingVerificationSnapshot()
            guard mode == .pendingVerification else { return }
            updatePendingScope(snapshot: snapshot, tracks: tracks)
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
}

extension WorkflowViewModel {
    private func preparePendingVerificationRun() {
        phase = .scanning
        processedCount = 0
        failedCount = 0
        currentTrackID = nil
        proposedChanges = []
        completedEntries = []
        result = nil
        dryRunReport = nil
    }

    private func runPendingVerification(
        tracks: [Track],
        pendingVerificationService: any PendingVerificationService
    ) async {
        do {
            let snapshot = await pendingVerificationSnapshot()
            let dueEntries = snapshot.due
            let contextTracks = await pendingVerificationContextTracks(from: tracks)
            updatePendingScope(snapshot: snapshot, tracks: contextTracks)
            preparePendingTrackStatuses(tracks: contextTracks, dueEntries: dueEntries)

            let albumGroups = Self.groupTracksByAlbum(contextTracks)
            var runOutcome = PendingEntryOutcome()
            var resolvedPendingKeys: Set<String> = []

            for (index, entry) in dueEntries.enumerated() {
                try Task.checkCancellation()
                updatePendingProgress(entry: entry, index: index, total: dueEntries.count)

                let entryKeys = Self.pendingIdentityKeys(for: entry)
                guard entryKeys.isDisjoint(with: resolvedPendingKeys) else {
                    continue
                }

                let albumTracks = Self.pendingAlbumTracks(for: entry, in: albumGroups)
                let entryOutcome = await processPendingEntry(
                    entry,
                    albumTracks: albumTracks,
                    albumGroups: albumGroups,
                    pendingVerificationService: pendingVerificationService
                )
                runOutcome.merge(entryOutcome)
                resolvedPendingKeys.formUnion(entryOutcome.resolvedIdentityKeys)
                processedCount += entryOutcome.processedCount
            }

            if !dueEntries.isEmpty {
                try await pendingVerificationService.updateVerificationTimestamp()
            }
            finishPendingVerification(runOutcome)
        } catch is CancellationError {
            currentTrackID = nil
            phase = .configure
            progress = nil
        } catch {
            currentTrackID = nil
            phase = .error(error.localizedDescription)
            progress = nil
        }
    }

    private func pendingVerificationContextTracks(from tracks: [Track]) async -> [Track] {
        let albumTracksByTrackID = await updateCoordinator.albumContextTracksByTrackID(for: tracks)
        var seenTrackIDs: Set<String> = []
        return tracks.flatMap { track in
            albumTracksByTrackID[track.id] ?? []
        }.filter { track in
            seenTrackIDs.insert(track.id).inserted
        }
    }

    private func preparePendingTrackStatuses(tracks: [Track], dueEntries: [PendingAlbumEntry]) {
        let scopedTracks = Self.tracksMatchingPendingEntries(tracks, entries: dueEntries)
        trackStatuses = Dictionary(uniqueKeysWithValues: scopedTracks.map { ($0.id, .queued) })
        totalCount = scopedTracks.count
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
        completedEntries = outcome.completed
        result = BatchUpdateResult(
            entries: outcome.completed,
            failedTrackIDs: outcome.failedTrackIDs,
            errorDescriptions: outcome.errorDescriptions
        )
        currentTrackID = nil
        phase = .done
        progress = nil
    }

    private func processPendingEntry(
        _ entry: PendingAlbumEntry,
        albumTracks: [Track],
        albumGroups: [String: [Track]],
        pendingVerificationService: any PendingVerificationService
    ) async -> PendingEntryOutcome {
        guard !albumTracks.isEmpty else {
            return PendingEntryOutcome(
                failedTrackIDs: [entry.id],
                errorDescriptions: ["No local tracks found for \(entry.artist) - \(entry.album)"]
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
        } catch {
            markPendingAlbumTracks(albumTracks, as: .failed(error.localizedDescription))
            return PendingEntryOutcome(
                failedTrackIDs: albumTracks.map(\.id),
                errorDescriptions: [error.localizedDescription],
                processedCount: albumTracks.count
            )
        }
    }

    private func pendingVerificationSnapshot() async -> (all: [PendingAlbumEntry], due: [PendingAlbumEntry]) {
        guard let pendingVerificationService else { return ([], []) }
        return await pendingVerificationService.getPendingVerificationSnapshot()
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

    private func handlePendingVerification(
        _ verification: PendingAlbumVerificationResult,
        entry: PendingAlbumEntry,
        albumTracks: [Track],
        albumGroups: [String: [Track]],
        pendingVerificationService: any PendingVerificationService
    ) async -> PendingEntryOutcome {
        if verification.didResolveYear {
            let removalIdentities = Self.pendingRemovalIdentities(entry: entry, albumTracks: albumTracks)
            let resolvedIdentityKeys = Self.pendingResolvedIdentityKeys(
                entry: entry,
                albumTracks: albumTracks,
                albumGroups: albumGroups
            )
            for identity in removalIdentities {
                await pendingVerificationService.removeFromPending(
                    artist: identity.artist,
                    album: identity.album
                )
            }
            markPendingAlbumTracks(albumTracks, as: .done)
            return PendingEntryOutcome(
                completed: verification.entries,
                processedCount: albumTracks.count,
                resolvedIdentityKeys: resolvedIdentityKeys
            )
        } else {
            markPendingAlbumTracks(albumTracks, as: .failed("No year resolved"))
            return PendingEntryOutcome(
                failedTrackIDs: albumTracks.map(\.id),
                errorDescriptions: ["No year resolved for \(entry.artist) - \(entry.album)"],
                processedCount: albumTracks.count
            )
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

    static func pendingAlbumTracks(
        for entry: PendingAlbumEntry,
        in albumGroups: [String: [Track]]
    ) -> [Track] {
        pendingAlbumTracks(artist: entry.artist, album: entry.album, in: albumGroups)
    }

    private static func pendingAlbumTracks(
        artist: String,
        album: String,
        in albumGroups: [String: [Track]]
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

    private static func pendingResolvedIdentityKeys(
        entry: PendingAlbumEntry,
        albumTracks: [Track],
        albumGroups: [String: [Track]]
    ) -> Set<String> {
        let albumTrackIDs = Set(albumTracks.map(\.id))
        var resolvedKeys = Set(pendingRemovalIdentities(entry: entry, albumTracks: albumTracks).map(\.key))
        var seenKeys = resolvedKeys

        for identity in albumTracks.flatMap(AlbumIdentity.lookupCandidates(for:))
            where seenKeys.insert(identity.key).inserted {
            let resolvedTracks = pendingAlbumTracks(
                artist: identity.artist,
                album: identity.album,
                in: albumGroups
            )
            if Set(resolvedTracks.map(\.id)) == albumTrackIDs {
                resolvedKeys.insert(identity.key)
            }
        }

        return resolvedKeys
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
}

extension PendingEntryOutcome {
    fileprivate mutating func merge(_ other: PendingEntryOutcome) {
        completed.append(contentsOf: other.completed)
        failedTrackIDs.append(contentsOf: other.failedTrackIDs)
        errorDescriptions.append(contentsOf: other.errorDescriptions)
        processedCount += other.processedCount
    }
}
