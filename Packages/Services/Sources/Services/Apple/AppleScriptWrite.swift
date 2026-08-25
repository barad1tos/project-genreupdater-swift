import Core
import Foundation

private let batchScriptName = "batch_update_tracks"

extension AppleScriptBridge {
    public func update(
        _ update: MusicTrackUpdate,
        onAttempt: @escaping WriteAttemptHook
    ) async throws -> MusicWriteResult {
        try await applySingleUpdate(update, onAttempt: onAttempt) { [self] in
            try await runScript(
                name: "update_property",
                arguments: [update.databaseID.rawValue, update.property.rawValue, update.value]
            )
        }
    }

    static func makeBatchUpdateArgument(_ updates: [MusicTrackUpdate]) throws -> String {
        let fieldSeparator = String(TrackWireCodec.fieldSeparator)
        let commandSeparator = String(TrackWireCodec.recordSeparator)
        return try updates.map { update -> String in
            let databaseID = update.databaseID.rawValue
            try validateBatchUpdateComponent(databaseID, label: "track ID")
            try validateBatchUpdateComponent(update.value, label: "value")
            let property = try validatedBatchUpdateProperty(update.property)
            return "\(databaseID)\(fieldSeparator)\(property)\(fieldSeparator)\(update.value)"
        }.joined(separator: commandSeparator)
    }

    private static func validatedBatchUpdateProperty(_ property: MusicTrackProperty) throws -> String {
        let rawValue = property.rawValue
        try validateBatchUpdateComponent(rawValue, label: "property")
        let sanitizedProperty = InputSanitizer.sanitizeScriptCode(rawValue)
        guard sanitizedProperty == rawValue else {
            throw AppleScriptBridgeError.executionFailed(
                scriptName: batchScriptName,
                detail: "Unsupported batch update property: \(rawValue)"
            )
        }
        return rawValue
    }

    private static func validateBatchUpdateComponent(_ value: String, label: String) throws {
        let containsReservedSeparator = value.contains(TrackWireCodec.fieldSeparator)
            || value.contains(TrackWireCodec.recordSeparator)
        guard !containsReservedSeparator else {
            throw AppleScriptBridgeError.executionFailed(
                scriptName: batchScriptName,
                detail: "Batch update \(label) contains a reserved separator"
            )
        }
    }

    static func verifyBatchUpdateValues(
        _ updates: [MusicTrackUpdate],
        in refreshedTracks: [Core.Track]
    ) throws {
        let requestedIDs = Set(updates.map(\.databaseID))
        var refreshedTracksByID: [MusicDatabaseTrackID: Core.Track] = [:]
        for track in refreshedTracks {
            guard let databaseID = track.databaseID,
                  requestedIDs.contains(databaseID),
                  refreshedTracksByID.updateValue(track, forKey: databaseID) == nil
            else {
                throw MusicBatchVerificationError(
                    updateCount: updates.count,
                    failedCount: nil,
                    reason: "Refreshed metadata did not contain unique requested database identities"
                )
            }
        }
        let failedUpdates = updates.filter { update in
            guard let track = refreshedTracksByID[update.databaseID],
                  let currentValue = update.property.currentValue(in: track)
            else {
                return true
            }
            return update.property.comparisonValue(currentValue)
                != update.property.comparisonValue(update.value)
        }

        guard failedUpdates.isEmpty else {
            throw MusicBatchVerificationError(
                updateCount: updates.count,
                failedCount: failedUpdates.count,
                reason: "Requested values were not visible after batch write"
            )
        }
    }

    static func validateBatchUpdateOutput(_ output: String?, updateCount: Int) throws {
        guard let output else {
            throw AppleScriptBridgeError.executionFailed(
                scriptName: batchScriptName,
                detail: "Batch of \(updateCount) updates, response=<empty>"
            )
        }

        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedOutput = trimmedOutput.lowercased()
        guard lowercasedOutput.hasPrefix("success:") else {
            throw AppleScriptBridgeError.executionFailed(
                scriptName: batchScriptName,
                detail: "Batch of \(updateCount) updates, response=\(String(trimmedOutput.prefix(200)))"
            )
        }
    }

    static func validateUpdatePropertyOutput(
        _ output: String?,
        update: MusicTrackUpdate
    ) throws -> MusicWriteResult {
        let databaseID = update.databaseID.rawValue
        let property = update.property.rawValue
        guard let output else {
            throw AppleScriptOutcomeError(
                scriptName: "update_property",
                reason: "returned no verifiable response for track \(databaseID), property \(property)"
            )
        }

        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedOutput = trimmedOutput.lowercased()
        if lowercasedOutput.hasPrefix("success:") {
            return .changed
        }
        if lowercasedOutput.hasPrefix("no change:") {
            return .noChange
        }

        throw AppleScriptOutcomeError(
            scriptName: "update_property",
            reason: "returned an unverifiable response for track \(databaseID), property \(property): "
                + String(trimmedOutput.prefix(200))
        )
    }
}
