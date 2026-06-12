// AppleScriptBridge.swift — Music.app write access via NSUserAppleScriptTask
// Ported from: src/services/apple/applescript_client.py (455 LOC)
//              + applescript_executor.py (337 LOC) → merged into actor
//
// CRITICAL ARCHITECTURE DECISION:
// NSUserAppleScriptTask runs scripts OUTSIDE the app sandbox — this is
// Apple's documented mechanism for sandboxed apps to execute AppleScripts.
// Scripts must live in ~/Library/Application Scripts/<bundle-id>/.
// ScriptInstaller handles copying them there during onboarding.
//
// Python used subprocess.run(["osascript", ...]) which can't work in a sandbox.
// NSUserAppleScriptTask is the MAS-compatible replacement.

import Carbon.OpenScripting
import Core
import Foundation
import OSLog

private let log = AppLogger.make(category: "applescript")

// MARK: - Errors

/// Errors from AppleScript execution.
public enum AppleScriptBridgeError: Error, LocalizedError {
    case scriptNotFound(name: String, searchPath: URL)
    case executionFailed(scriptName: String, detail: String)
    case timeout(scriptName: String, duration: Duration)
    case parseError(scriptName: String, detail: String)
    case scriptsNotInstalled
    case musicAppNotRunning

    public var errorDescription: String? {
        switch self {
        case let .scriptNotFound(name, path):
            "Script '\(name).scpt' not found at \(path.path)"
        case let .executionFailed(name, detail):
            "AppleScript '\(name)' failed: \(detail)"
        case let .timeout(name, duration):
            "AppleScript '\(name)' timed out after \(duration)"
        case let .parseError(name, detail):
            "Failed to parse output from '\(name)': \(detail)"
        case .scriptsNotInstalled:
            "AppleScript files are not installed. Please run the setup wizard."
        case .musicAppNotRunning:
            "Music.app is not running. Please start Music.app before using Genre Updater."
        }
    }
}

// MARK: - Sendable Wrapper

// Safety: NSUserAppleScriptTask and NSAppleEventDescriptor are not Sendable
// but are safe here — actor serialization ensures only one task executes at a time.
private struct UnsafeSendable<T>: @unchecked Sendable {
    let value: T
}

// MARK: - AppleScript Bridge Actor

/// Actor that manages all AppleScript interactions with Music.app.
///
/// Uses NSUserAppleScriptTask for sandbox-compatible script execution.
/// The actor ensures serialized access to Music.app, preventing race conditions
/// that occur when multiple AppleScript calls run concurrently.
public actor AppleScriptBridge: AppleScriptClient {
    private let installer: ScriptInstaller
    private var config: AppleScriptConfig

    public init(installer: ScriptInstaller, config: AppleScriptConfig = .init()) {
        self.installer = installer
        self.config = config
    }

    public func updateConfiguration(_ config: AppleScriptConfig) {
        self.config = config
    }

    public func initialize() async throws {
        let installed = await installer.areScriptsInstalled()
        guard installed else {
            throw AppleScriptBridgeError.scriptsNotInstalled
        }
        log.info("AppleScript bridge initialized — all scripts present")
    }

    // MARK: - Script Execution

    public func runScript(
        name: String,
        arguments: [String] = [],
        timeout: Duration? = nil
    ) async throws -> String? {
        let scriptURL = await installer.scriptURL(for: name)

        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw AppleScriptBridgeError.scriptNotFound(name: name, searchPath: scriptURL.deletingLastPathComponent())
        }

        let runScriptSignpost = AppSignpost.appleScriptWrite.beginInterval("runScript")
        defer { AppSignpost.appleScriptWrite.endInterval("runScript", runScriptSignpost) }

        // Sanitize arguments
        let sanitizedArgs = try InputSanitizer.sanitizeArguments(arguments)

        log.info("Executing script: \(name, privacy: .public) with \(sanitizedArgs.count, privacy: .public) arguments")

        let task = try NSUserAppleScriptTask(url: scriptURL)

        // Build Apple Event with arguments
        let event = try buildAppleEvent(arguments: sanitizedArgs)
        let effectiveTimeout = timeout ?? config.timeouts.defaultTimeout

        // Execute with timeout
        // NSUserAppleScriptTask/NSAppleEventDescriptor are not Sendable but safe here —
        // the actor serializes all calls, and only one TaskGroup child uses them.
        let wrappedTask = UnsafeSendable(value: task)
        let wrappedEvent = UnsafeSendable(value: event)
        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                let descriptor = try await wrappedTask.value.execute(withAppleEvent: wrappedEvent.value)
                return descriptor.stringValue
            }

            group.addTask {
                try await Task.sleep(for: effectiveTimeout)
                throw AppleScriptBridgeError.timeout(scriptName: name, duration: effectiveTimeout)
            }

            // Return first completed result, cancel the other
            let result = try await group.next()
            group.cancelAll()
            return result.flatMap(\.self)
        }
    }

    // MARK: - Track Operations

    public func fetchTracksByIDs(
        _ trackIDs: [String],
        batchSize: Int = 1000,
        timeout: Duration? = nil
    ) async throws -> [Core.Track] {
        var allTracks: [Core.Track] = []
        let effectiveTimeout = timeout ?? config.timeouts.idsBatchFetch

        for batch in trackIDs.chunked(into: batchSize) {
            let idsArg = batch.joined(separator: ",")
            guard let output = try await runScript(
                name: "fetch_tracks_by_ids",
                arguments: [idsArg],
                timeout: effectiveTimeout
            ) else {
                continue
            }

            let tracks = parseTrackOutput(output)
            allTracks.append(contentsOf: tracks)
        }

        log
            .info(
                "Fetched \(allTracks.count, privacy: .public) tracks by IDs (\(trackIDs.count, privacy: .public) requested)"
            )
        return allTracks
    }

    public func fetchAllTrackIDs(timeout: Duration? = nil) async throws -> [String] {
        let effectiveTimeout = timeout ?? config.timeouts.fullLibraryFetch
        guard let output = try await runScript(name: "fetch_track_ids", timeout: effectiveTimeout) else {
            return []
        }

        // fetch_track_ids.applescript returns comma-separated IDs
        let ids = output.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        log.info("Fetched \(ids.count, privacy: .public) track IDs from library")
        return ids
    }

    // MARK: - Music.app Write Operations

    /// Update a property of a track in Music.app.
    public func updateTrackProperty(trackID: String, property: String, value: String) async throws {
        let output = try await runScript(
            name: "update_property",
            arguments: [trackID, property, value]
        )
        log
            .info(
                "Updated \(property, privacy: .public) for track \(trackID, privacy: .private): \(value, privacy: .private)"
            )

        if let output, output.lowercased().contains("error") {
            throw AppleScriptBridgeError.executionFailed(
                scriptName: "update_property",
                detail: "Track=\(trackID), property=\(property), response=\(output)"
            )
        }
    }

    /// Batch update multiple tracks' properties.
    public func batchUpdateTracks(_ updates: [(trackID: String, property: String, value: String)]) async throws {
        let batchUpdateSignpost = AppSignpost.appleScriptWrite.beginInterval("batchUpdateTracks")
        defer { AppSignpost.appleScriptWrite.endInterval("batchUpdateTracks", batchUpdateSignpost) }

        // Format matches batch_update_tracks.applescript:
        // Fields separated by ASCII 30 (Record Separator), commands by ASCII 29 (Group Separator).
        let fieldSep = String(Core.Track.fieldSeparator) // \x1E — between fields
        let commandSep = String(Core.Track.recordSeparator) // \x1D — between commands
        let batchArg: String = updates.map { update -> String in
            let escapedID = InputSanitizer.escapeStringValue(update.trackID)
            let escapedProperty = InputSanitizer.sanitizeScriptCode(update.property)
            let escapedValue = InputSanitizer.escapeStringValue(update.value)
            return "\(escapedID)\(fieldSep)\(escapedProperty)\(fieldSep)\(escapedValue)"
        }.joined(separator: commandSep)

        let output = try await runScript(
            name: "batch_update_tracks",
            arguments: [batchArg],
            timeout: config.timeouts.batchUpdate
        )

        log.info("Batch updated \(updates.count, privacy: .public) tracks")

        if let output, output.lowercased().contains("error") {
            throw AppleScriptBridgeError.executionFailed(
                scriptName: "batch_update_tracks",
                detail: "Batch of \(updates.count) updates, response=\(String(output.prefix(200)))"
            )
        }
    }

    // MARK: - Private Helpers

    /// Build an NSAppleEventDescriptor with string arguments.
    private func buildAppleEvent(arguments: [String]) throws -> NSAppleEventDescriptor? {
        guard !arguments.isEmpty else { return nil }

        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )

        let argList = NSAppleEventDescriptor.list()
        for (index, arg) in arguments.enumerated() {
            argList.insert(NSAppleEventDescriptor(string: arg), at: index + 1)
        }
        event.setDescriptor(argList, forKeyword: keyDirectObject)

        return event
    }

    /// Parse AppleScript output into Track objects.
    private func parseTrackOutput(_ output: String) -> [Core.Track] {
        output.split(separator: Core.Track.recordSeparator)
            .compactMap { Core.Track.fromAppleScriptOutput(String($0)) }
    }
}

// MARK: - Array Chunking

extension Array {
    /// Split array into chunks of the given size.
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
