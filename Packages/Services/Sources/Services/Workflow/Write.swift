import Core
import Foundation

extension UpdateCoordinator {
    typealias AppliedChangeEntries = (entries: [ChangeLogEntry], noOpEntries: [ChangeLogEntry])
    typealias AppliedChangeOutcome = (entry: ChangeLogEntry?, noOpEntry: ChangeLogEntry?)
    typealias UpdateTrackProviders = (album: @Sendable (Track) -> [Track], artist: @Sendable (Track) -> [Track])

    func consecutiveChangesForSameTrack(
        in changes: [ProposedChange],
        startingAt startIndex: Int
    ) -> [ProposedChange] {
        guard let firstChange = changes[safe: startIndex] else { return [] }
        var group: [ProposedChange] = []

        for change in changes[startIndex...] {
            guard change.track.id == firstChange.track.id else { break }
            group.append(change)
        }

        return group
    }

    func reviewedChangeGroup(
        in changes: [ProposedChange],
        startingAt startIndex: Int
    ) -> [ProposedChange] {
        let sameTrackGroup = consecutiveChangesForSameTrack(in: changes, startingAt: startIndex)
        if sameTrackGroup.count > 1 {
            return sameTrackGroup
        }

        guard runtimeConfiguration.areBatchUpdatesEnabled,
              runtimeConfiguration.maxBatchUpdateSize > 1,
              let firstChange = changes[safe: startIndex],
              Self.isAlbumYearBatchCandidate(firstChange)
        else {
            return sameTrackGroup
        }

        var group: [ProposedChange] = []
        for change in changes[startIndex...] {
            guard group.count < runtimeConfiguration.maxBatchUpdateSize,
                  Self.isAlbumYearBatchCandidate(change, matching: firstChange)
            else {
                break
            }
            group.append(change)
        }

        return group.count > 1 ? group : sameTrackGroup
    }

    private static func isAlbumYearBatchCandidate(
        _ change: ProposedChange,
        matching firstChange: ProposedChange
    ) -> Bool {
        isAlbumYearBatchCandidate(change)
            && change.newValue == firstChange.newValue
            && hasMatchingAlbumBatchIdentity(change.track, firstChange.track)
    }

    private static func isAlbumYearBatchCandidate(_ change: ProposedChange) -> Bool {
        switch change.changeType {
        case .yearUpdate, .yearRevert:
            change.newValue != nil
        case .genreUpdate, .trackCleaning, .albumCleaning, .artistRename:
            false
        }
    }

    private static func hasMatchingAlbumBatchIdentity(_ track: Track, _ otherTrack: Track) -> Bool {
        let identity = track.albumIdentity
        guard identity.isComplete else { return false }
        return identity.key == otherTrack.albumIdentity.key
    }

    func applyReviewedChangeGroup(
        _ changes: [ProposedChange],
        failedTrackIDs: inout [String],
        errorDescriptions: inout [String],
        checkpoint: WorkCheckpointSink? = nil
    ) async throws -> AppliedChangeEntries {
        if let applied = try await applyChangesAsBatchIfPossible(
            changes,
            isReviewedChange: true,
            failedTrackIDs: &failedTrackIDs,
            errorDescriptions: &errorDescriptions,
            checkpoint: checkpoint
        ) {
            return applied
        }

        var entries: [ChangeLogEntry] = []
        var noOpEntries: [ChangeLogEntry] = []
        for change in changes {
            do {
                let outcome = try await applyChangeOutcome(
                    change,
                    isReviewedChange: true,
                    checkpoint: checkpoint
                )
                if let entry = outcome.entry {
                    entries.append(entry)
                }
                if let noOpEntry = outcome.noOpEntry {
                    noOpEntries.append(noOpEntry)
                }
            } catch {
                if let partialWrite = error as? PartialWriteError {
                    throw partialWrite
                }
                if Self.shouldPropagateWriteFailure(error) {
                    guard !entries.isEmpty else { throw error }
                    throw PartialWriteError(
                        appliedTrackIDs: Set(entries.map(\.trackID)),
                        underlyingError: error
                    )
                }
                try recordWorkflowWriteFailure(
                    error,
                    isReviewedChange: true,
                    trackID: change.track.id,
                    failedTrackIDs: &failedTrackIDs,
                    errorDescriptions: &errorDescriptions
                )
            }
        }
        return (entries, noOpEntries)
    }

    private static func shouldPropagateWriteFailure(_ error: any Error) -> Bool {
        error is CancellationError || error is WorkCheckpointError || error is AppleScriptOutcomeError
    }

    func applyGeneratedAcceptedChanges(
        for track: Track,
        options: UpdateOptions,
        trackProviders: UpdateTrackProviders,
        failedTrackIDs: inout [String],
        errorDescriptions: inout [String]
    ) async throws -> AppliedChangeEntries {
        let albumTracksWithMutationMetadata = await availableTracksWithMutationMetadata(
            trackProviders.album(track)
        )
        let artistTracks = trackProviders.artist(track).filter(Self.isTrackAvailableForProcessing)
        let changes = try await updateTrack(
            track,
            albumTracks: albumTracksWithMutationMetadata,
            artistTracks: artistTracks,
            options: options,
            dryRun: true
        )

        let acceptedChanges = changes.filter(\.isAccepted)
        do {
            if let applied = try await applyChangesAsBatchIfPossible(
                acceptedChanges,
                isReviewedChange: false,
                failedTrackIDs: &failedTrackIDs,
                errorDescriptions: &errorDescriptions
            ) {
                return applied
            }
        } catch let partialWrite as PartialWriteError {
            throw partialWrite.underlyingError
        }

        var entries: [ChangeLogEntry] = []
        var noOpEntries: [ChangeLogEntry] = []
        for change in acceptedChanges {
            do {
                let outcome = try await applyChangeOutcome(change, isReviewedChange: false)
                if let entry = outcome.entry {
                    entries.append(entry)
                }
                if let noOpEntry = outcome.noOpEntry {
                    noOpEntries.append(noOpEntry)
                }
            } catch {
                try recordWorkflowWriteFailure(
                    error,
                    isReviewedChange: false,
                    trackID: change.track.id,
                    failedTrackIDs: &failedTrackIDs,
                    errorDescriptions: &errorDescriptions
                )
            }
        }
        return (entries, noOpEntries)
    }
}
