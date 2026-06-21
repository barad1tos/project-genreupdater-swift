// WorkflowViewModel+PendingVerification.swift -- Pending album verification workflow.

import Core
import Services

private struct PendingEntryOutcome {
    var completed: [ChangeLogEntry] = []
    var failedTrackIDs: [String] = []
    var errorDescriptions: [String] = []
    var processedCount = 0
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
            updatePendingScope(snapshot: snapshot, tracks: tracks)
            preparePendingTrackStatuses(tracks: tracks, dueEntries: dueEntries)

            let albumGroups = Self.groupTracksByAlbum(tracks)
            var runOutcome = PendingEntryOutcome()

            for (index, entry) in dueEntries.enumerated() {
                try Task.checkCancellation()
                updatePendingProgress(entry: entry, index: index, total: dueEntries.count)

                let albumTracks = albumGroups[Self.albumKey(artist: entry.artist, album: entry.album)] ?? []
                let entryOutcome = await processPendingEntry(
                    entry,
                    albumTracks: albumTracks,
                    pendingVerificationService: pendingVerificationService
                )
                runOutcome.merge(entryOutcome)
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

        let allEntries = await pendingVerificationService.getAllPendingAlbums()
        var dueEntries: [PendingAlbumEntry] = []
        for entry in allEntries {
            let isDue = await pendingVerificationService.isVerificationNeeded(artist: entry.artist, album: entry.album)
            guard isDue else { continue }
            dueEntries.append(entry)
        }
        return (allEntries, dueEntries)
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
        pendingVerificationService: any PendingVerificationService
    ) async -> PendingEntryOutcome {
        if verification.didResolveYear {
            await pendingVerificationService.removeFromPending(
                artist: entry.artist,
                album: entry.album
            )
            markPendingAlbumTracks(albumTracks, as: .done)
            return PendingEntryOutcome(
                completed: verification.entries,
                processedCount: albumTracks.count
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
        let pendingKeys = Set(entries.map { albumKey(artist: $0.artist, album: $0.album) })
        return tracks.filter { pendingKeys.contains(albumKey(for: $0)) }
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
        albumKey(artist: track.artist, album: track.album)
    }

    static func albumKey(artist: String, album: String) -> String {
        [
            artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
        ].joined(separator: "\u{1F}")
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
