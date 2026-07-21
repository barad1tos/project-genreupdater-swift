import Core
import Foundation
import OSLog

struct PreparedWrite {
    let change: ProposedChange
    let trackID: String
    let property: String
    let value: String
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
            try await checkpoint?(.afterVerification([change.id: .noFixNeeded]))
            await invalidateCaches(for: change)
            return (nil, entry)
        case .skipped:
            try await checkpoint?(.afterVerification([change.id: .skipped]))
            return (nil, nil)
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
            try await checkpoint?(.afterVerification([change.id: .failed]))
            throw error
        }
    }

    private func applyPreparedWrite(
        _ write: PreparedWrite,
        checkpoint: WorkCheckpointSink?
    ) async throws -> AppliedChangeOutcome {
        try await checkpoint?(.beforeAttempt([write.change.id]))
        let result = try await dispatchWrite(write, checkpoint: checkpoint)
        guard result == .changed else {
            try await checkpoint?(.afterVerification([write.change.id: .noFixNeeded]))
            await invalidateCaches(for: write.change)
            logNoOp(write.change)
            return (nil, Self.noOpLogEntry(write.change))
        }

        let entry = try await recordAppliedChange(write.change)
        try await checkpoint?(.afterVerification([write.change.id: .written]))
        return (entry, nil)
    }

    private func dispatchWrite(
        _ write: PreparedWrite,
        checkpoint: WorkCheckpointSink?
    ) async throws -> AppleScriptWriteResult {
        let attemptState = WriteAttemptState()
        do {
            return try await scriptBridge.updateTrackProperty(
                trackID: write.trackID,
                property: write.property,
                value: write.value,
                onAttempt: {
                    attemptState.markAttempted()
                    try await checkpoint?(.afterAttempt([write.change.id]))
                }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WorkCheckpointError {
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
            try await checkpoint?(.afterVerification([write.change.id: .failed]))
            throw UpdateCoordinatorError.writeFailed(
                trackID: write.change.track.id,
                property: write.property,
                reason: error.localizedDescription
            )
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
        guard mutationTrack.canEdit else {
            throw UpdateCoordinatorError.trackNotEditable(trackID: mutationTrack.id)
        }
        guard Self.isTrackAvailableForProcessing(mutationTrack) else {
            throw UpdateCoordinatorError.trackNotProcessable(
                trackID: mutationTrack.id,
                status: mutationTrack.trackStatus ?? "unknown"
            )
        }
        let property = Self.appleScriptProperty(for: change.changeType)
        if isReviewedChange,
           try !shouldWrite(change, to: mutationTrack, property: property) {
            log.info(
                """
                Skipped reviewed \(change.changeType.rawValue, privacy: .public) for track \
                \(change.track.id, privacy: .private) after write preflight
                """
            )
            return .noOp(Self.noOpLogEntry(change))
        }

        let writeID = try await writeID(for: mutationTrack)
        return .write(PreparedWrite(
            change: change,
            trackID: writeID,
            property: property,
            value: newValue
        ))
    }

    func shouldWrite(
        _ change: ProposedChange,
        to mutationTrack: Track,
        property: String,
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
                property: property
            )
        }
        return true
    }

    private func writeID(for track: Track) async throws -> String {
        guard let idMapper else { return track.id }
        guard let appleScriptID = await idMapper.appleScriptID(forMusicKitID: track.id) else {
            throw UpdateCoordinatorError.missingAppleScriptID(trackID: track.id)
        }
        return appleScriptID
    }

    private static func valueMatches(_ expectedValue: String?, in track: Track, property: String) -> Bool {
        normalizedReviewedValue(expectedValue) == normalizedReviewedValue(value(
            forAppleScriptProperty: property,
            in: track
        ))
    }

    private static func normalizedReviewedValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    func recordAppliedChange(_ change: ProposedChange) async throws -> ChangeLogEntry {
        let entry = Self.changeToLogEntry(change)
        var failedEffects: [String] = []
        do {
            try await undoCoordinator.recordChange(entry)
        } catch {
            failedEffects.append("change history")
            log.error("""
            Failed to persist change history for track \(change.track.id, privacy: .private): \
            \(error.localizedDescription, privacy: .public)
            """)
        }
        do {
            try await trackStore.updateTrackProcessingState(
                id: change.track.id,
                genreUpdated: change.changeType == .genreUpdate ? true : nil,
                yearUpdated: change.changeType == .yearUpdate || change.changeType == .yearRevert ? true : nil
            )
        } catch {
            failedEffects.append("track processing state")
            log.error("""
            Failed to persist processing state for track \(change.track.id, privacy: .private): \
            \(error.localizedDescription, privacy: .public)
            """)
        }
        await invalidateCaches(for: change)
        guard failedEffects.isEmpty else {
            throw UpdateCoordinatorError.writeFinalizationFailed(
                trackID: change.track.id,
                effects: failedEffects
            )
        }
        log.info(
            "Applied \(change.changeType.rawValue, privacy: .public) to track \(change.track.id, privacy: .private)"
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
