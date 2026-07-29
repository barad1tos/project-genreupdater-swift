import Foundation

/// Result of a single Music.app metadata write.
public enum AppleScriptWriteResult: Sendable, Equatable {
    case changed
    case noChange
}

/// Error thrown when a batch script may have run but its final metadata state cannot be verified.
public struct AppleScriptBatchVerificationError: Error, LocalizedError, Sendable, Equatable {
    public let updateCount: Int
    public let failedCount: Int?
    public let reason: String

    public init(updateCount: Int, failedCount: Int?, reason: String) {
        self.updateCount = updateCount
        self.failedCount = failedCount
        self.reason = reason
    }

    public var errorDescription: String? {
        if let failedCount {
            return "Batch verification failed for \(failedCount) of \(updateCount) updates: \(reason)"
        }
        return "Batch verification failed for \(updateCount) updates: \(reason)"
    }
}

/// Error thrown when an AppleScript read helper cannot map a non-empty record to a track.
public struct AppleScriptClientParseError: Error, LocalizedError, Sendable, Equatable {
    public let scriptName: String
    public let detail: String

    public var errorDescription: String? {
        "Failed to parse output from '\(scriptName)': \(detail)"
    }
}

/// Reports that a Music.app mutation may have been dispatched.
public typealias WriteAttemptHook = @Sendable () async throws -> Void

/// One property mutation sent to Music.app as part of a batch.
public struct TrackPropertyUpdate: Equatable, Sendable {
    public let trackID: String
    public let property: String
    public let value: String

    public init(trackID: String, property: String, value: String) {
        self.trackID = trackID
        self.property = property
        self.value = value
    }
}

/// Preserves both a failed write and the failed attempt checkpoint that followed it.
public struct WriteAttemptFailure: Error {
    public let writeError: any Error
    public let checkpointError: any Error

    public init(writeError: any Error, checkpointError: any Error) {
        self.writeError = writeError
        self.checkpointError = checkpointError
    }
}

/// Protocol for interacting with Music.app via AppleScript.
///
/// The actor requirement serializes access to bridge state; script
/// concurrency is bounded separately by the configured dispatch gate.
public protocol AppleScriptClient: Actor {
    func initialize() async throws

    func runScript(
        name: String,
        arguments: [String],
        timeout: Duration?
    ) async throws -> String?

    func fetchTracksByIDs(
        _ trackIDs: [String],
        batchSize: Int,
        timeout: Duration?
    ) async throws -> [Track]

    func fetchAllTrackIDs(timeout: Duration?) async throws -> [String]
    func fetchTracks(artist: String?, timeout: Duration?) async throws -> [Track]
    func updateTrackProperty(trackID: String, property: String, value: String) async throws -> AppleScriptWriteResult

    func updateTrackProperty(
        trackID: String,
        property: String,
        value: String,
        onAttempt: @escaping WriteAttemptHook
    ) async throws -> AppleScriptWriteResult

    func batchUpdateTracks(_ updates: [TrackPropertyUpdate]) async throws

    func batchUpdateTracks(
        _ updates: [TrackPropertyUpdate],
        onAttempt: @escaping WriteAttemptHook
    ) async throws
}

extension AppleScriptClient {
    public func updateTrackProperty(
        trackID: String,
        property: String,
        value: String,
        onAttempt: @escaping WriteAttemptHook
    ) async throws -> AppleScriptWriteResult {
        let result: AppleScriptWriteResult
        do {
            result = try await updateTrackProperty(trackID: trackID, property: property, value: value)
        } catch {
            try await finishFailedAttempt(error, onAttempt: onAttempt)
        }
        try await onAttempt()
        return result
    }

    public func batchUpdateTracks(
        _ updates: [TrackPropertyUpdate],
        onAttempt: @escaping WriteAttemptHook
    ) async throws {
        do {
            try await batchUpdateTracks(updates)
        } catch {
            try await finishFailedAttempt(error, onAttempt: onAttempt)
        }
        try await onAttempt()
    }

    private func finishFailedAttempt(
        _ writeError: any Error,
        onAttempt: WriteAttemptHook
    ) async throws -> Never {
        do {
            try await onAttempt()
        } catch {
            throw WriteAttemptFailure(writeError: writeError, checkpointError: error)
        }
        throw writeError
    }

    public func runScript(name: String, arguments: [String] = [], timeout: Duration? = nil) async throws -> String? {
        try await runScript(name: name, arguments: arguments, timeout: timeout)
    }

    public func fetchTracks(artist: String? = nil, timeout: Duration? = nil) async throws -> [Track] {
        let arguments = artist.map { [$0] } ?? []
        let output = try await runScript(
            name: "fetch_tracks",
            arguments: arguments,
            timeout: timeout
        )
        guard let output, output != "NO_TRACKS_FOUND" else { return [] }
        return try Self.parseTrackRecords(output, scriptName: "fetch_tracks")
    }

    public static func parseTrackRecords(_ output: String, scriptName: String) throws -> [Track] {
        var tracks: [Track] = []
        for record in output.split(separator: Track.recordSeparator, omittingEmptySubsequences: false) {
            let rawRecord = String(record)
            guard !rawRecord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            guard let track = Track.fromAppleScriptOutput(rawRecord) else {
                let fieldCount = rawRecord.split(separator: Track.fieldSeparator, omittingEmptySubsequences: false)
                    .count
                throw AppleScriptClientParseError(
                    scriptName: scriptName,
                    detail: "Malformed track record: expected 12 fields, got \(fieldCount)"
                )
            }
            tracks.append(track)
        }
        return tracks
    }
}
