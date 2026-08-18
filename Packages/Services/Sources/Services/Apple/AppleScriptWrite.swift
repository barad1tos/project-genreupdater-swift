import Core
import Foundation

private let batchScriptName = "batch_update_tracks"

extension AppleScriptBridge {
    /// Update a property of a track in Music.app.
    public func updateTrackProperty(
        trackID: String,
        property: String,
        value: String
    ) async throws -> AppleScriptWriteResult {
        try await updateTrackProperty(
            trackID: trackID,
            property: property,
            value: value,
            onAttempt: nil
        ) { [self] in
            try await runScript(
                name: "update_property",
                arguments: [trackID, property, value]
            )
        }
    }

    public func updateTrackProperty(
        trackID: String,
        property: String,
        value: String,
        onAttempt: @escaping WriteAttemptHook
    ) async throws -> AppleScriptWriteResult {
        try await updateTrackProperty(
            trackID: trackID,
            property: property,
            value: value,
            onAttempt: onAttempt
        ) { [self] in
            try await runScript(
                name: "update_property",
                arguments: [trackID, property, value]
            )
        }
    }

    static func makeBatchUpdateArgument(_ updates: [TrackPropertyUpdate]) throws
        -> String {
        let fieldSep = String(Core.Track.fieldSeparator) // \x1E — between fields
        let commandSep = String(Core.Track.recordSeparator) // \x1D — between commands
        return try updates.map { update -> String in
            try validateBatchUpdateComponent(update.trackID, label: "track ID")
            try validateBatchUpdateComponent(update.value, label: "value")
            let property = try validatedBatchUpdateProperty(update.property)
            return "\(update.trackID)\(fieldSep)\(property)\(fieldSep)\(update.value)"
        }.joined(separator: commandSep)
    }

    private static func validatedBatchUpdateProperty(_ property: String) throws -> String {
        try validateBatchUpdateComponent(property, label: "property")
        let sanitizedProperty = InputSanitizer.sanitizeScriptCode(property)
        guard sanitizedProperty == property,
              AppleScriptTrackProperty.supportedNames.contains(property)
        else {
            throw AppleScriptBridgeError.executionFailed(
                scriptName: batchScriptName,
                detail: "Unsupported batch update property: \(property)"
            )
        }
        return property
    }

    private static func validateBatchUpdateComponent(_ value: String, label: String) throws {
        let containsReservedSeparator = value.contains(Core.Track.fieldSeparator)
            || value.contains(Core.Track.recordSeparator)
        guard !containsReservedSeparator else {
            throw AppleScriptBridgeError.executionFailed(
                scriptName: batchScriptName,
                detail: "Batch update \(label) contains a reserved separator"
            )
        }
    }

    static func verifyBatchUpdateValues(
        _ updates: [TrackPropertyUpdate],
        in refreshedTracks: [Core.Track]
    ) throws {
        let refreshedTracksByID = Dictionary(
            refreshedTracks.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let failedUpdates = updates.filter { update in
            guard let track = refreshedTracksByID[update.trackID],
                  let property = AppleScriptTrackProperty(rawValue: update.property),
                  let currentValue = property.currentValue(in: track)
            else {
                return true
            }
            return property.comparisonValue(currentValue) != property.comparisonValue(update.value)
        }

        guard failedUpdates.isEmpty else {
            throw AppleScriptBatchVerificationError(
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
        trackID: String,
        property: String
    ) throws -> AppleScriptWriteResult {
        guard let output else {
            throw AppleScriptOutcomeError(
                scriptName: "update_property",
                reason: "returned no verifiable response for track \(trackID), property \(property)"
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
            reason: "returned an unverifiable response for track \(trackID), property \(property): "
                + String(trimmedOutput.prefix(200))
        )
    }
}
