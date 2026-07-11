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
    case dispatchDeadline(scriptName: String, duration: Duration)
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
        case let .dispatchDeadline(name, duration):
            "AppleScript '\(name)' was not dispatched before its \(duration) deadline"
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
// but each wrapped value is confined to one bounded AppleScript execution.
private struct UnsafeSendable<T>: @unchecked Sendable {
    let value: T
}

// MARK: - AppleScript Bridge Actor

/// Actor that manages all AppleScript interactions with Music.app.
///
/// Uses NSUserAppleScriptTask for sandbox-compatible script execution.
/// The actor applies configured read retries, rate, and concurrency limits before
/// reaching Music.app.
public actor AppleScriptBridge: AppleScriptClient {
    private static let batchUpdateScriptName = "batch_update_tracks"

    private let installer: ScriptInstaller
    private var config: AppleScriptConfig
    private var rateLimiter: TokenBucketRateLimiter?
    private let concurrencyGate: ScriptGate

    public init(installer: ScriptInstaller, config: AppleScriptConfig = .init()) {
        self.installer = installer
        self.config = config
        self.rateLimiter = Self.makeRateLimiter(configuration: config.rateLimit)
        self.concurrencyGate = ScriptGate(limit: config.concurrency)
    }

    public var trackIDBatchSize: Int {
        max(1, config.batchProcessing.idsBatchSize)
    }

    public func updateConfiguration(_ config: AppleScriptConfig) async {
        await concurrencyGate.updateLimit(config.concurrency)
        self.config = config
        rateLimiter = Self.makeRateLimiter(configuration: config.rateLimit)
    }

    func acquirePermit(
        scriptName: String,
        deadline: ContinuousClock.Instant,
        timeout: Duration
    ) async throws -> ScriptPermit {
        try await concurrencyGate.acquire(
            scriptName: scriptName,
            deadline: deadline,
            timeout: timeout
        )
    }

    public func initialize() async throws {
        let installed = await installer.areScriptsCurrent()
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

        let validatedArguments = try InputSanitizer.validateAppleEventArguments(arguments)
        let effectiveTimeout = timeout ?? config.timeouts.defaultTimeout
        let retryConfiguration = config.retry
        let intent = Self.intent(forScript: name)

        log
            .info(
                "Executing script: \(name, privacy: .public) with \(validatedArguments.count, privacy: .public) arguments"
            )

        // Writes surface their first outcome so recovery can verify Music.app state before any replay.
        guard intent == .read else {
            return try await executeScriptAttempt(
                name: name,
                scriptURL: scriptURL,
                arguments: validatedArguments,
                timeout: effectiveTimeout
            )
        }

        let deadline = ContinuousClock().now.advanced(by: effectiveTimeout)
        return try await retryRead(
            scriptName: name,
            retry: retryConfiguration,
            deadline: deadline,
            timeout: effectiveTimeout
        ) { attemptTimeout in
            try await self.executeScriptAttempt(
                name: name,
                scriptURL: scriptURL,
                arguments: validatedArguments,
                timeout: attemptTimeout
            )
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
        let effectiveBatchSize = max(1, batchSize)

        for batch in trackIDs.chunked(into: effectiveBatchSize) {
            let idsArg = batch.joined(separator: ",")
            guard let output = try await runScript(
                name: "fetch_tracks_by_ids",
                arguments: [idsArg],
                timeout: effectiveTimeout
            ) else {
                continue
            }

            let tracks = try Self.parseTrackOutput(output)
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

        let ids = try Self.parseTrackIDOutput(output)
        log.info("Fetched \(ids.count, privacy: .public) track IDs from library")
        return ids
    }

    // MARK: - Music.app Write Operations

    /// Update a property of a track in Music.app.
    public func updateTrackProperty(
        trackID: String,
        property: String,
        value: String
    ) async throws -> AppleScriptWriteResult {
        let output = try await runScript(
            name: "update_property",
            arguments: [trackID, property, value]
        )
        let result = try Self.validateUpdatePropertyOutput(output, trackID: trackID, property: property)

        log
            .info(
                "Completed update_property for \(property, privacy: .public) on track \(trackID, privacy: .private): \(value, privacy: .private)"
            )
        return result
    }

    /// Batch update multiple tracks' properties.
    public func batchUpdateTracks(_ updates: [(trackID: String, property: String, value: String)]) async throws {
        try await batchUpdateTracks(updates) { [self] batchArgument in
            try await runScript(
                name: Self.batchUpdateScriptName,
                arguments: [batchArgument],
                timeout: config.timeouts.batchUpdate
            )
        }
    }

    func batchUpdateTracks(
        _ updates: [(trackID: String, property: String, value: String)],
        execute: (String) async throws -> String?
    ) async throws {
        let batchUpdateSignpost = AppSignpost.appleScriptWrite.beginInterval("batchUpdateTracks")
        defer { AppSignpost.appleScriptWrite.endInterval("batchUpdateTracks", batchUpdateSignpost) }

        // Format matches batch_update_tracks.applescript:
        // Fields separated by ASCII 30 (Record Separator), commands by ASCII 29 (Group Separator).
        guard !updates.isEmpty else { return }

        try await ensureBatchUpdateScriptExists()
        let batchArg = try Self.makeBatchUpdateArgument(updates)
        _ = try InputSanitizer.validateAppleEventArguments([batchArg])

        let output: String?
        do {
            output = try await execute(batchArg)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AppleScriptBridgeError where Self.isDispatchDeadline(error) {
            // Music.app was never reached, so the caller may safely fall back to single writes.
            throw error
        } catch {
            throw AppleScriptBatchVerificationError(
                updateCount: updates.count,
                failedCount: nil,
                reason: "Batch script did not return a verifiable result: \(error.localizedDescription)"
            )
        }

        do {
            try Self.validateBatchUpdateOutput(output, updateCount: updates.count)
        } catch {
            throw AppleScriptBatchVerificationError(
                updateCount: updates.count,
                failedCount: nil,
                reason: "Batch script returned an unverifiable response: \(error.localizedDescription)"
            )
        }
        try await verifyBatchUpdateResult(updates)
        log.info("Batch updated \(updates.count, privacy: .public) tracks")
    }

    private func ensureBatchUpdateScriptExists() async throws {
        let scriptURL = await installer.scriptURL(for: Self.batchUpdateScriptName)
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw AppleScriptBridgeError.scriptNotFound(
                name: Self.batchUpdateScriptName,
                searchPath: scriptURL.deletingLastPathComponent()
            )
        }
    }

    static func makeBatchUpdateArgument(_ updates: [(trackID: String, property: String, value: String)]) throws
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
                scriptName: batchUpdateScriptName,
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
                scriptName: batchUpdateScriptName,
                detail: "Batch update \(label) contains a reserved separator"
            )
        }
    }

    private func verifyBatchUpdateResult(
        _ updates: [(trackID: String, property: String, value: String)]
    ) async throws {
        let trackIDs = Array(Set(updates.map(\.trackID)))
        let refreshedTracks: [Core.Track]
        do {
            refreshedTracks = try await fetchTracksByIDs(
                trackIDs,
                batchSize: trackIDBatchSize,
                timeout: config.timeouts.idsBatchFetch
            )
        } catch {
            throw AppleScriptBatchVerificationError(
                updateCount: updates.count,
                failedCount: nil,
                reason: "Could not refresh tracks after batch write: \(error.localizedDescription)"
            )
        }
        try Self.verifyBatchUpdateValues(updates, in: refreshedTracks)
    }

    static func verifyBatchUpdateValues(
        _ updates: [(trackID: String, property: String, value: String)],
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
            return currentValue != update.value
        }

        guard failedUpdates.isEmpty else {
            throw AppleScriptBatchVerificationError(
                updateCount: updates.count,
                failedCount: failedUpdates.count,
                reason: "Requested values were not visible after batch write"
            )
        }
    }

    // MARK: - Private Helpers

    /// Build an NSAppleEventDescriptor with string arguments.
    private func buildAppleEvent(arguments: [String]) throws -> NSAppleEventDescriptor? {
        Self.makeRunAppleEvent(arguments: arguments)
    }

    static func makeRunAppleEvent(arguments: [String]) -> NSAppleEventDescriptor? {
        guard !arguments.isEmpty else { return nil }

        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
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

    /// Parse comma-separated IDs returned by fetch_track_ids.applescript.
    static func parseTrackIDOutput(_ output: String) throws -> [String] {
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutput.isEmpty else { return [] }
        if trimmedOutput.localizedCaseInsensitiveContains("ERROR:") {
            throw AppleScriptBridgeError.executionFailed(
                scriptName: "fetch_track_ids",
                detail: String(trimmedOutput.prefix(200))
            )
        }
        guard trimmedOutput != "NO_TRACKS_FOUND" else { return [] }

        return output
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func validateBatchUpdateOutput(_ output: String?, updateCount: Int) throws {
        guard let output else {
            throw AppleScriptBridgeError.executionFailed(
                scriptName: batchUpdateScriptName,
                detail: "Batch of \(updateCount) updates, response=<empty>"
            )
        }

        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedOutput = trimmedOutput.lowercased()
        guard lowercasedOutput.hasPrefix("success:") else {
            throw AppleScriptBridgeError.executionFailed(
                scriptName: batchUpdateScriptName,
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
            throw AppleScriptBridgeError.executionFailed(
                scriptName: "update_property",
                detail: "Track=\(trackID), property=\(property), response=<empty>"
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

        throw AppleScriptBridgeError.executionFailed(
            scriptName: "update_property",
            detail: "Track=\(trackID), property=\(property), response=\(String(trimmedOutput.prefix(200)))"
        )
    }

    /// Parse AppleScript output into Track objects.
    static func parseTrackOutput(_ output: String) throws -> [Core.Track] {
        do {
            return try parseTrackRecords(output, scriptName: "fetch_tracks_by_ids")
        } catch let error as AppleScriptClientParseError {
            throw AppleScriptBridgeError.parseError(scriptName: error.scriptName, detail: error.detail)
        }
    }
}

extension AppleScriptBridge {
    func executeScriptAttempt(
        name: String,
        scriptURL: URL,
        arguments: [String],
        timeout: Duration
    ) async throws -> String? {
        if let rateLimiter {
            let waitTime = await rateLimiter.acquire()
            if waitTime > .zero {
                log.debug("AppleScript rate limited, waited \(waitTime, privacy: .public)")
            }
        }

        let task = try NSUserAppleScriptTask(url: scriptURL)
        let event = try buildAppleEvent(arguments: arguments)

        let wrappedTask = UnsafeSendable(value: task)
        let wrappedEvent = UnsafeSendable(value: event)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        let permit = try await acquirePermit(
            scriptName: name,
            deadline: deadline,
            timeout: timeout
        )
        defer { permit.release() }
        return try await Self.executeBeforeDeadline(
            deadline: deadline,
            scriptName: name,
            timeout: timeout
        ) {
            let descriptor = try await wrappedTask.value.execute(withAppleEvent: wrappedEvent.value)
            return descriptor.stringValue
        }
    }

    static func executeBeforeDeadline<Value: Sendable>(
        deadline: ContinuousClock.Instant,
        scriptName: String,
        timeout: Duration,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let remaining = ContinuousClock().now.duration(to: deadline)
        guard remaining > .zero else {
            throw AppleScriptBridgeError.dispatchDeadline(scriptName: scriptName, duration: timeout)
        }
        // Timeout delivery remains cooperative when the operation ignores cancellation.
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(for: remaining)
                throw AppleScriptBridgeError.timeout(scriptName: scriptName, duration: timeout)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw AppleScriptBridgeError.executionFailed(
                    scriptName: scriptName,
                    detail: "Execution ended without a result"
                )
            }
            return result
        }
    }

    static func makeRateLimiter(configuration: AppleScriptRateLimit) -> TokenBucketRateLimiter? {
        guard configuration.enabled else { return nil }

        let requestCount = max(1, configuration.requestsPerWindow)
        let refillMilliseconds = max(1, Int((configuration.windowSizeSeconds / Double(requestCount)) * 1000))
        return TokenBucketRateLimiter(
            maxTokens: requestCount,
            refillInterval: .milliseconds(refillMilliseconds)
        )
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
