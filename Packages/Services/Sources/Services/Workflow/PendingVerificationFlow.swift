import Core

extension UpdateCoordinator {
    /// Resolve a pending album through the API path and apply the resolved year to all album tracks.
    public func verifyPendingAlbum(
        _ entry: PendingAlbumEntry,
        albumTracks: [Track]
    ) async throws -> PendingAlbumVerificationResult {
        guard !albumTracks.isEmpty else {
            return PendingAlbumVerificationResult(entries: [], resolvedYear: nil)
        }

        guard let identity = Self.pendingVerificationIdentity(for: entry, albumTracks: albumTracks) else {
            return PendingAlbumVerificationResult(entries: [], resolvedYear: nil)
        }
        let yearLookup = await apiOrchestrator.getAlbumYearForPendingVerification(
            artist: identity.artist,
            album: identity.album,
            currentLibraryYear: nil,
            earliestTrackAddedYear: earliestAddedYear(albumTracks)
        )
        let yearResult = yearLookup.result

        guard let year = yearResult.year else {
            if yearLookup.didAttemptLookup {
                await markPendingVerificationRetries(entry: entry, lookupIdentity: identity)
            }
            return PendingAlbumVerificationResult(entries: [], resolvedYear: nil)
        }

        var entries: [ChangeLogEntry] = []
        var unchangedTrackIDs: [String] = []
        var failedTrackIDs: [String] = []
        var errorDescriptions: [String] = []
        for track in albumTracks where track.year != year {
            let change = ProposedChange(
                track: track,
                changeType: .yearUpdate,
                oldValue: track.year.map(String.init),
                newValue: String(year),
                confidence: yearResult.confidence,
                source: yearResult.isDefinitive ? "Definitive" : "API"
            )
            guard runtimeConfiguration.allowsChange(change) else {
                failedTrackIDs.append(track.id)
                errorDescriptions.append(
                    "Skipped pending verification for track \(track.id) outside test artist allow-list"
                )
                continue
            }
            if let entry = try await applyPendingVerificationChange(
                change,
                failedTrackIDs: &failedTrackIDs,
                errorDescriptions: &errorDescriptions
            ) {
                entries.append(entry)
            } else {
                unchangedTrackIDs.append(track.id)
            }
        }

        return PendingAlbumVerificationResult(
            entries: entries,
            resolvedYear: year,
            unchangedTrackIDs: unchangedTrackIDs,
            failedTrackIDs: failedTrackIDs,
            errorDescriptions: errorDescriptions,
            canClearPendingEntry: failedTrackIDs.isEmpty
                && (yearResult.isDefinitive || !entries.isEmpty || !unchangedTrackIDs.isEmpty)
        )
    }

    private func markPendingVerificationRetries(entry: PendingAlbumEntry, lookupIdentity: AlbumIdentity) async {
        guard let pendingVerificationService else { return }

        let retryEntries = await pendingVerificationRetryEntries(
            entry: entry,
            lookupIdentity: lookupIdentity,
            pendingVerificationService: pendingVerificationService
        )
        for retryEntry in retryEntries {
            await pendingVerificationService.markForVerification(
                artist: retryEntry.artist,
                album: retryEntry.album,
                reason: retryEntry.reason,
                metadata: [
                    "source": "pending_verification",
                    "lookup_artist": lookupIdentity.artist,
                ],
                recheckDays: nil
            )
        }
    }

    private func pendingVerificationRetryEntries(
        entry: PendingAlbumEntry,
        lookupIdentity: AlbumIdentity,
        pendingVerificationService: any PendingVerificationService
    ) async -> [PendingAlbumEntry] {
        let targetReason = Self.normalizedPendingReason(entry.reason)
        var targetKeys = Set(AlbumIdentity.lookupKeys(artist: entry.artist, album: entry.album))
        targetKeys.formUnion(AlbumIdentity.lookupKeys(artist: lookupIdentity.artist, album: lookupIdentity.album))

        var seenKeys: Set<String> = []
        var retryEntries: [PendingAlbumEntry] = []

        func append(_ pendingEntry: PendingAlbumEntry) {
            let key = AlbumIdentity.key(artist: pendingEntry.artist, album: pendingEntry.album)
            guard seenKeys.insert(key).inserted else { return }
            retryEntries.append(pendingEntry)
        }

        append(entry)

        let pendingEntries = await pendingVerificationService.getAllPendingAlbums()
        for pendingEntry in pendingEntries where Self.normalizedPendingReason(pendingEntry.reason) == targetReason {
            let pendingKeys = Set(AlbumIdentity.lookupKeys(artist: pendingEntry.artist, album: pendingEntry.album))
            guard !pendingKeys.isDisjoint(with: targetKeys) else { continue }
            append(pendingEntry)
        }

        return retryEntries
    }

    private static func normalizedPendingReason(_ reason: String) -> String {
        let normalizedReason = reason
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
        if normalizedReason == "pre_release" {
            return "prerelease"
        }
        return normalizedReason
    }

    private func applyPendingVerificationChange(
        _ change: ProposedChange,
        failedTrackIDs: inout [String],
        errorDescriptions: inout [String]
    ) async throws -> ChangeLogEntry? {
        do {
            return try await applyChange(change)
        } catch let error as CancellationError {
            throw error
        } catch let error as UpdateCoordinatorError {
            if !recordKnownWorkflowFailure(
                error,
                fallbackTrackID: change.track.id,
                isReviewedChange: false,
                failedTrackIDs: &failedTrackIDs,
                errorDescriptions: &errorDescriptions
            ) {
                recordUnexpectedWorkflowFailure(
                    trackID: change.track.id,
                    error: error,
                    failedTrackIDs: &failedTrackIDs,
                    errorDescriptions: &errorDescriptions
                )
            }
            return nil
        } catch {
            recordUnexpectedWorkflowFailure(
                trackID: change.track.id,
                error: error,
                failedTrackIDs: &failedTrackIDs,
                errorDescriptions: &errorDescriptions
            )
            return nil
        }
    }

    private static func pendingVerificationIdentity(
        for entry: PendingAlbumEntry,
        albumTracks: [Track]
    ) -> AlbumIdentity? {
        let pendingKeys = Set(AlbumIdentity.lookupKeys(artist: entry.artist, album: entry.album))
        guard let identity = albumTracks.first(where: { track in
            let trackKeys = Set(AlbumIdentity.lookupKeys(for: track))
            return !pendingKeys.isDisjoint(with: trackKeys)
        })?.albumIdentity else {
            return nil
        }

        guard albumTracks.allSatisfy({ $0.albumIdentity == identity }) else {
            return nil
        }
        return identity
    }
}
