import Core
import Foundation
import OSLog

struct PreparedWrite {
    let change: ProposedChange
    let databaseID: MusicDatabaseTrackID
    let property: MusicTrackProperty
    let value: String
    let updates: [MusicTrackUpdate]

    init(
        change: ProposedChange,
        databaseID: MusicDatabaseTrackID,
        property: MusicTrackProperty,
        value: String
    ) throws {
        self.change = change
        self.databaseID = databaseID
        self.property = property
        self.value = value
        var updates = try [MusicTrackUpdate(databaseID: databaseID, property: property, value: value)]
        if let albumArtistChange = change.albumArtistChange {
            try updates.append(MusicTrackUpdate(
                databaseID: databaseID,
                property: .albumArtist,
                value: albumArtistChange.newValue
            ))
        }
        self.updates = updates
    }

    var writeChange: WorkChange {
        WorkChange(
            changeType: change.changeType,
            oldValue: change.oldValue,
            newValue: change.newValue,
            confidence: change.confidence,
            source: change.source,
            albumArtistChange: change.albumArtistChange
        )
    }

    func dispatch(
        using mutator: any MusicAppMutating,
        onAttempt: @escaping WriteAttemptHook
    ) async throws -> MusicWriteResult {
        guard updates.count > 1 else {
            return try await mutator.update(updates[0], onAttempt: onAttempt)
        }
        try await mutator.update(updates, onAttempt: onAttempt)
        return .changed
    }
}

final class WriteAttemptState: @unchecked Sendable {
    private let lock = NSLock()
    private var attempted = false

    var hasAttempted: Bool {
        lock.withLock { attempted }
    }

    func markAttempted() {
        lock.withLock { attempted = true }
    }
}

enum PreparedWriteOutcome {
    case write(PreparedWrite)
    case noOp(ChangeLogEntry)
    case skipped
}

extension UpdateCoordinator {
    @discardableResult
    func applyChange(
        _ change: ProposedChange,
        isReviewedChange: Bool = true
    ) async throws -> ChangeLogEntry? {
        try await applyChangeOutcome(change, isReviewedChange: isReviewedChange).entry
    }

    func applyChangeOutcome(
        _ change: ProposedChange,
        isReviewedChange: Bool = true,
        checkpoint: WorkCheckpointSink? = nil
    ) async throws -> AppliedChangeOutcome {
        let outcome = try await prepareChange(
            change,
            isReviewedChange: isReviewedChange,
            checkpoint: checkpoint
        )
        switch outcome {
        case let .write(write):
            return try await applyPreparedWrite(write, checkpoint: checkpoint)
        case let .noOp(entry):
            await invalidateCaches(for: change)
            try await checkpoint?(.afterVerification([change.id: .noFixNeeded]))
            return (nil, entry)
        case .skipped:
            try await checkpoint?(.afterVerification([change.id: .skipped]))
            return (nil, nil)
        }
    }

    private func checkpointFailedWrite(
        _ changeID: UUID,
        primaryError: any Error,
        sink: WorkCheckpointSink?
    ) async throws {
        do {
            try await sink?(.afterVerification([changeID: .failed]))
        } catch {
            log.error("""
            Write failed with \(String(describing: type(of: primaryError)), privacy: .public): \
            \(primaryError.localizedDescription, privacy: .private); its failed-outcome checkpoint also failed with \
            \(String(describing: type(of: error)), privacy: .public): \
            \(error.localizedDescription, privacy: .private)
            """)
            throw error
        }
    }

    private func prepareChange(
        _ change: ProposedChange,
        isReviewedChange: Bool,
        checkpoint: WorkCheckpointSink?
    ) async throws -> PreparedWriteOutcome {
        do {
            return try await prepareWrite(
                for: change,
                isReviewedChange: isReviewedChange
            )
        } catch {
            try await checkpointFailedWrite(
                change.id,
                primaryError: error,
                sink: checkpoint
            )
            throw error
        }
    }

    private func applyPreparedWrite(
        _ write: PreparedWrite,
        checkpoint: WorkCheckpointSink?
    ) async throws -> AppliedChangeOutcome {
        try await checkpoint?(.beforeAttempt([write.change.id: write.writeChange]))
        let result = try await dispatchWrite(write, checkpoint: checkpoint)
        guard result == .changed else {
            await invalidateCaches(for: write.change)
            try await checkpoint?(.afterVerification([write.change.id: .noFixNeeded]))
            logNoOp(write.change)
            return (nil, Self.noOpLogEntry(write.change))
        }

        // Checkpoint the verified outcome before finalization (same contract as
        // the batch path): a finalization failure must not erase it, and a
        // checkpoint failure must still invalidate caches for the landed write.
        do {
            try await checkpoint?(.afterVerification([write.change.id: .written]))
        } catch {
            await invalidateCaches(for: write.change)
            throw error
        }
        let entry = try await recordAppliedChange(write.change, databaseID: write.databaseID)
        return (entry, nil)
    }

    private func dispatchWrite(
        _ write: PreparedWrite,
        checkpoint: WorkCheckpointSink?
    ) async throws -> MusicWriteResult {
        let attemptState = WriteAttemptState()
        do {
            return try await write.dispatch(
                using: mutationAccess(),
                onAttempt: {
                    attemptState.markAttempted()
                    try await checkpoint?(.afterAttempt([write.change.id]))
                }
            )
        } catch is CancellationError {
            if attemptState.hasAttempted {
                await invalidateCaches(for: write.change)
            }
            throw CancellationError()
        } catch let failure as WriteAttemptFailure {
            if attemptState.hasAttempted {
                await invalidateCaches(for: write.change)
            }
            throw reportAttemptFailure(failure)
        } catch let error as WorkCheckpointError {
            if attemptState.hasAttempted {
                await invalidateCaches(for: write.change)
            }
            throw error
        } catch let error as AppleScriptOutcomeError {
            await invalidateCaches(for: write.change)
            throw error
        } catch let error where attemptState.hasAttempted {
            await invalidateCaches(for: write.change)
            throw AppleScriptOutcomeError(
                scriptName: "update_property",
                reason: "returned an error after dispatch: \(error.localizedDescription)"
            )
        } catch {
            let writeFailure = UpdateCoordinatorError.writeFailed(
                trackID: write.databaseID.rawValue,
                property: write.property.rawValue,
                reason: error.localizedDescription
            )
            try await checkpointFailedWrite(
                write.change.id,
                primaryError: writeFailure,
                sink: checkpoint
            )
            throw writeFailure
        }
    }

    func prepareWrite(
        for change: ProposedChange,
        isReviewedChange: Bool = true
    ) async throws -> PreparedWriteOutcome {
        guard runtimeConfiguration.allowsChange(change) else {
            log.info(
                "Skipped change for track \(change.track.id, privacy: .private) outside test artist allow-list"
            )
            return .skipped
        }

        guard let newValue = change.newValue else { return .skipped }
        let mutationTrack = try await trackWithMutationMetadata(change.track)
        let preparedChange = Self.reconciledArtistRename(change, with: mutationTrack)
        try Self.validateMutationEligibility(
            for: mutationTrack,
            requiresKnownStatus: idMapper != nil
        )
        let property = Self.musicProperty(for: preparedChange.changeType)
        if isReviewedChange,
           idMapper != nil,
           let albumArtistChange = preparedChange.albumArtistChange,
           Self.valueMatches(preparedChange.newValue, in: mutationTrack, property: property),
           Self.valueMatches(
               albumArtistChange.newValue,
               in: mutationTrack,
               property: .albumArtist
           ) {
            return .noOp(Self.noOpLogEntry(preparedChange))
        }
        if isReviewedChange,
           try !shouldWrite(preparedChange, to: mutationTrack, property: property) {
            log.info(
                """
                Skipped reviewed \(preparedChange.changeType.rawValue, privacy: .public) for track \
                \(preparedChange.track.id, privacy: .private) after write preflight
                """
            )
            return .noOp(Self.noOpLogEntry(preparedChange))
        }

        let databaseID = try await databaseID(for: mutationTrack)
        return try .write(PreparedWrite(
            change: preparedChange,
            databaseID: databaseID,
            property: property,
            value: newValue
        ))
    }

    static func reconciledArtistRename(
        _ change: ProposedChange,
        with mutationTrack: Track
    ) -> ProposedChange {
        guard change.changeType == .artistRename,
              let plannedAlbumEffect = change.albumArtistChange,
              let oldArtist = change.oldValue,
              let newArtist = change.newValue,
              let currentAlbumArtist = mutationTrack.albumArtist
        else {
            return change.changeType == .artistRename
                ? change.copy(albumArtistChange: nil)
                : change
        }

        let normalizedAlbumArtist = normalizeForMatching(currentAlbumArtist)
        let albumArtistChange: AlbumArtistChange? = if normalizedAlbumArtist == normalizeForMatching(oldArtist) {
            AlbumArtistChange(oldValue: currentAlbumArtist, newValue: newArtist)
        } else if normalizedAlbumArtist == normalizeForMatching(newArtist) {
            plannedAlbumEffect
        } else {
            nil
        }
        return change.copy(albumArtistChange: albumArtistChange)
    }

    func shouldWrite(
        _ change: ProposedChange,
        to mutationTrack: Track,
        property: MusicTrackProperty,
        staleTrackID: String? = nil
    ) throws -> Bool {
        if change.changeType == .yearUpdate, mutationTrack.hasBeenProcessed {
            return false
        }
        guard Self.valueMatches(change.oldValue, in: mutationTrack, property: property) ||
            Self.valueMatches(change.newValue, in: mutationTrack, property: property)
        else {
            throw UpdateCoordinatorError.reviewedChangeStale(
                trackID: staleTrackID ?? mutationTrack.id,
                property: property.rawValue
            )
        }
        return true
    }

    private func databaseID(for track: Track) async throws -> MusicDatabaseTrackID {
        guard let idMapper else {
            guard let databaseID = track.databaseID else {
                throw UpdateCoordinatorError.missingAppleScriptID(trackID: track.id)
            }
            return databaseID
        }
        guard let appleScriptID = await idMapper.appleScriptID(forMusicKitID: track.id),
              let databaseID = MusicDatabaseTrackID(rawValue: appleScriptID)
        else {
            throw UpdateCoordinatorError.missingAppleScriptID(trackID: track.id)
        }
        return databaseID
    }

    private static func valueMatches(
        _ expectedValue: String?,
        in track: Track,
        property: MusicTrackProperty
    ) -> Bool {
        let expected = property.comparisonValue(normalizedReviewedValue(expectedValue))
        let current = property.comparisonValue(normalizedReviewedValue(property.currentValue(in: track)))
        return expected == current
    }

    private static func normalizedReviewedValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    func recordAppliedChange(
        _ change: ProposedChange,
        databaseID: MusicDatabaseTrackID
    ) async throws -> ChangeLogEntry {
        let entry = attributed(Self.changeToLogEntry(change, databaseID: databaseID))
        do {
            _ = try await trackStore.commitAppliedChange(entry)
            await undoCoordinator.recordCommittedChange(entry)
        } catch {
            log.error("""
            Failed to finalize applied change for track \(databaseID.rawValue, privacy: .private): \
            \(error.localizedDescription, privacy: .private)
            """)
            throw UpdateCoordinatorError.writeFinalizationFailed(
                trackID: databaseID.rawValue,
                effects: ["track mirror", "change history"]
            )
        }
        await invalidateCaches(for: change)
        log.info(
            "Applied \(change.changeType.rawValue, privacy: .public) to track \(databaseID.rawValue, privacy: .private)"
        )
        return entry
    }

    private func logNoOp(_ change: ProposedChange) {
        log.info(
            """
            Skipped applied-change record for no-op \(change.changeType.rawValue, privacy: .public) on track \
            \(change.track.id, privacy: .private)
            """
        )
    }
}

extension ProposedChange {
    func copy(track: Track? = nil, albumArtistChange: AlbumArtistChange?) -> Self {
        ProposedChange(
            id: id,
            track: track ?? self.track,
            changeType: changeType,
            oldValue: oldValue,
            newValue: newValue,
            confidence: confidence,
            source: source,
            isAccepted: isAccepted,
            albumArtistChange: albumArtistChange
        )
    }
}
